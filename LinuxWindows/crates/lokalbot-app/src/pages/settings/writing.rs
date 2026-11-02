//! Writing: autocomplete, its practice editor, the writing profile and
//! exclusions (`AutocompleteExperienceView.swift`, `SettingsView.cotypingSection`).
//! The writing profile is also what Compose dictation writes as.
//!
//! The practice editor goes through the same engine path as a field in
//! another app: its text is sent as a field context, the suggestion is drawn
//! after its caret, the accept keys take the next word or phrase or the rest,
//! and Esc dismisses.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{
    Escape as InputEscape, IndentInline, Input, InputEvent, InputState, MoveRight, OutdentInline,
    Textarea, TextareaState,
};
use gpui_kit::component::slider::Slider;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Entity, FontWeight, InteractiveElement as _,
    IntoElement, KeyDownEvent, ParentElement as _, SharedString, Styled as _, Subscription, Window,
    canvas, div, px,
};
use lokalbot_ai::autocomplete::memory;
use lokalbot_ai::autocomplete::server::{self, Route};
use lokalbot_core::Settings;
use lokalbot_core::cotyping_stats::UsageRange;
use lokalbot_core::settings::{
    AcceptGranularity, CotypingAcceptKey, CotypingBackend, CotypingEscapeBehavior,
    CotypingFullAcceptKey,
};
use lokalbot_engine::{AutocompleteCommand, Command};
use lokalbot_platform::autocomplete::session::replaced_bytes;
use lokalbot_platform::autocomplete::{AcceptKeys, InterceptedKey, Support};

use super::{Section, SettingsPage, models, writing_rehearsal, writing_server};
use crate::state::{AppEvent, SettingsCategory};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico, settings_row};

/// What the practice editor starts with (`AutocompleteExperienceView.openingText`).
pub const PRACTICE_OPENING: &str = "Hi Sarah, thanks for the update. I wanted to follow";

pub fn granularity_label(granularity: AcceptGranularity) -> &'static str {
    match granularity {
        AcceptGranularity::Word => lokalbot_i18n::tr("One word"),
        AcceptGranularity::Phrase => lokalbot_i18n::tr("One phrase"),
    }
}

pub fn accept_key_label(key: CotypingAcceptKey) -> &'static str {
    match key {
        CotypingAcceptKey::Tab => lokalbot_i18n::tr("Tab"),
        CotypingAcceptKey::RightArrow => lokalbot_i18n::tr("Right Arrow"),
    }
}

pub fn full_accept_key_label(key: CotypingFullAcceptKey) -> &'static str {
    match key {
        CotypingFullAcceptKey::Backtick => "`",
        CotypingFullAcceptKey::RightArrow => lokalbot_i18n::tr("Right Arrow"),
        CotypingFullAcceptKey::Off => lokalbot_i18n::tr("Off"),
    }
}

pub fn escape_label(behavior: CotypingEscapeBehavior) -> &'static str {
    match behavior {
        CotypingEscapeBehavior::Pause => lokalbot_i18n::tr("Dismiss and pause briefly"),
        CotypingEscapeBehavior::PassThrough => {
            lokalbot_i18n::tr("Dismiss and send Escape to the app")
        }
    }
}

/// One line saying what the accept keys do (`CotypingAcceptHint`).
pub fn accept_hint(settings: &Settings) -> String {
    let key = accept_key_label(settings.cotyping_accept_key).to_string();
    let first = if settings.cotyping_accept_granularity == AcceptGranularity::Word {
        lokalbot_i18n::format("{0} accepts the next word", &[("0", key)])
    } else {
        lokalbot_i18n::format("{0} accepts the next phrase", &[("0", key)])
    };
    let mut parts = vec![first];
    // The primary key wins when both are bound to the same key.
    let keys = AcceptKeys::from_settings(settings);
    if keys.full.is_some() {
        parts.push(lokalbot_i18n::format(
            "{0} accepts the rest",
            &[(
                "0",
                full_accept_key_label(settings.cotyping_full_accept_key).to_string(),
            )],
        ));
    }
    parts.push(lokalbot_i18n::tr("Esc dismisses").to_string());
    parts.join(" · ")
}

/// How long a saved-memory count stays good before Settings reads it again.
const INVENTORY_LIFETIME: std::time::Duration = std::time::Duration::from_secs(30);

/// What is saved and readable, counted without reading any text into the UI
/// (`CotypingContextAvailability.Inventory`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Inventory {
    recent_meetings: usize,
    meeting_facts: usize,
    screen_facts: usize,
    mixed_facts: usize,
}

/// What an optional context source can contribute right now, shown under its
/// switch, so a grant that is on but cannot take effect says why.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum ContextState {
    Off,
    Available(String),
    Unavailable(String),
    NothingSaved(String),
}

fn counted_meetings(count: usize) -> String {
    if count == 1 {
        lokalbot_i18n::tr("1 meeting").to_string()
    } else {
        lokalbot_i18n::format("{0} meetings", &[("0", count.to_string())])
    }
}

fn counted_facts(count: usize) -> String {
    if count == 1 {
        lokalbot_i18n::tr("1 saved fact").to_string()
    } else {
        lokalbot_i18n::format("{0} saved facts", &[("0", count.to_string())])
    }
}

fn visible_text_state(settings: &Settings, other_apps: bool) -> ContextState {
    if !settings.cotyping_use_visible_context {
        return ContextState::Off;
    }
    if !settings.cotyping_enabled {
        return ContextState::Unavailable(
            lokalbot_i18n::tr("Unavailable: autocomplete is off.").to_string(),
        );
    }
    if !other_apps {
        return ContextState::Unavailable(
            lokalbot_i18n::tr("Unavailable: this desktop does not let LokalBot read other apps.")
                .to_string(),
        );
    }
    ContextState::Available(
        lokalbot_i18n::tr("Available in apps that expose their text to accessibility.").to_string(),
    )
}

fn window_text_state(settings: &Settings, other_apps: bool, ocr_ready: bool) -> ContextState {
    if !settings.cotyping_use_window_text {
        return ContextState::Off;
    }
    if !settings.cotyping_enabled {
        return ContextState::Unavailable(
            lokalbot_i18n::tr("Unavailable: autocomplete is off.").to_string(),
        );
    }
    if !other_apps {
        return ContextState::Unavailable(
            lokalbot_i18n::tr("Unavailable: this desktop does not let LokalBot read other apps.")
                .to_string(),
        );
    }
    if !ocr_ready {
        return ContextState::Unavailable(
            lokalbot_i18n::tr("Unavailable: the text recognition model is not downloaded.")
                .to_string(),
        );
    }
    ContextState::Available(
        lokalbot_i18n::tr(
            "Available in every app except excluded apps, sites and private windows.",
        )
        .to_string(),
    )
}

fn meeting_memory_state(settings: &Settings, inventory: &Inventory) -> ContextState {
    if !settings.cotyping_use_meeting_memory {
        return ContextState::Off;
    }
    if inventory.recent_meetings == 0 && inventory.meeting_facts == 0 {
        return ContextState::NothingSaved(
            lokalbot_i18n::tr("Nothing to use yet: no meetings or meeting-derived work memory in the last 90 days.").to_string(),
        );
    }
    let mut parts = Vec::new();
    if inventory.recent_meetings > 0 {
        parts.push(counted_meetings(inventory.recent_meetings));
    }
    if inventory.meeting_facts > 0 {
        parts.push(counted_facts(inventory.meeting_facts));
    }
    ContextState::Available(lokalbot_i18n::format(
        "Available: {0} from the last 90 days.",
        &[("0", parts.join(" and "))],
    ))
}

fn screen_memory_state(settings: &Settings, inventory: &Inventory) -> ContextState {
    if !settings.cotyping_use_screen_memory {
        return ContextState::Off;
    }
    // A fact built from meetings and screen activity needs both grants.
    let blocked = if settings.cotyping_use_meeting_memory {
        0
    } else {
        inventory.mixed_facts
    };
    let usable = inventory.screen_facts + inventory.mixed_facts - blocked;
    if usable > 0 {
        let mut text = lokalbot_i18n::format(
            "Available: {0} from the last 90 days.",
            &[("0", counted_facts(usable))],
        );
        if blocked > 0 {
            text.push(' ');
            text.push_str(&lokalbot_i18n::format(
                "{0} more also draw on meetings and need Use meeting and work memory.",
                &[("0", blocked.to_string())],
            ));
        }
        return ContextState::Available(text);
    }
    if blocked > 0 {
        return ContextState::Unavailable(if blocked == 1 {
            lokalbot_i18n::tr("Unavailable: the 1 saved fact also draws on meetings. Turn on Use meeting and work memory.").to_string()
        } else {
            lokalbot_i18n::format(
                "Unavailable: the {0} saved facts also draw on meetings. Turn on Use meeting and work memory.",
                &[("0", blocked.to_string())],
            )
        });
    }
    ContextState::NothingSaved(if settings.dreaming_enabled {
        lokalbot_i18n::tr(
            "Nothing to use yet: no screen-derived work memory is saved. Overnight review adds it.",
        )
        .to_string()
    } else {
        lokalbot_i18n::tr("Nothing to use yet: no screen-derived work memory is saved, and Overnight review is off, so none is being added.").to_string()
    })
}

/// Autocomplete's editors and view state in Settings → Writing.
pub struct WritingState {
    languages: Entity<InputState>,
    notes: Entity<TextareaState>,
    pub(super) server: writing_server::ServerDraft,
    pub(super) range: UsageRange,
    /// The chart shows words rather than the share of suggestions used.
    pub(super) chart_words: bool,
    pub(super) timing_open: bool,
    inventory: Option<(std::time::Instant, Inventory)>,
}

impl WritingState {
    pub fn new(settings: &Settings, window: &mut Window, cx: &mut Context<SettingsPage>) -> Self {
        let languages = cx.new(|cx| {
            InputState::new(window, cx)
                .placeholder(crate::i18n::placeholder(
                    "Optional, e.g. English, German",
                    window,
                    cx,
                ))
                .default_value(settings.cotyping_languages.clone())
        });
        let notes = cx.new(|cx| {
            TextareaState::new(window, cx)
                .rows(3)
                .placeholder(crate::i18n::placeholder(
                    "Names and jargon to keep in mind",
                    window,
                    cx,
                ))
                .default_value(settings.cotyping_extended_context.clone())
        });
        Self {
            languages,
            notes,
            server: writing_server::ServerDraft::new(settings, window, cx),
            range: UsageRange::default(),
            chart_words: true,
            timing_open: false,
            inventory: None,
        }
    }

    pub fn subscribe(
        state: &WritingState,
        window: &mut Window,
        cx: &mut Context<SettingsPage>,
    ) -> Vec<Subscription> {
        let mut subscriptions = vec![
            cx.subscribe_in(
                &state.languages,
                window,
                |this, input, event: &InputEvent, _, cx| {
                    if matches!(event, InputEvent::Change) {
                        let value = input.read(cx).value().to_string();
                        this.update_settings(move |s| s.cotyping_languages = value, cx);
                    }
                },
            ),
            cx.subscribe_in(
                &state.notes,
                window,
                |this, input, event: &InputEvent, _, cx| {
                    if matches!(event, InputEvent::Change) {
                        let value = input.read(cx).value().to_string();
                        this.update_settings(move |s| s.cotyping_extended_context = value, cx);
                    }
                },
            ),
        ];
        subscriptions.extend(writing_server::ServerDraft::subscribe(
            &state.server,
            window,
            cx,
        ));
        subscriptions
    }

    pub fn sync(&mut self, settings: &Settings, window: &mut Window, cx: &mut App) {
        super::sync_input(&self.languages, &settings.cotyping_languages, window, cx);
        super::sync_text(&self.notes, &settings.cotyping_extended_context, window, cx);
    }
}

impl SettingsPage {
    /// Sends the practice editor's text around its caret to the engine when
    /// it changed.
    pub(super) fn practice_sync(&mut self, cx: &mut Context<Self>) {
        let (before, after) = {
            let state = self.practice.read(cx);
            let value = state.value();
            let cursor = state.cursor().min(value.len());
            let before = value.get(..cursor).unwrap_or(value.as_ref()).to_string();
            let after = value.get(cursor..).unwrap_or_default().to_string();
            (before, after)
        };
        if self.practice_text == (before.clone(), after.clone()) {
            return;
        }
        self.practice_text = (before.clone(), after.clone());
        // The ghost is placed from the caret the editor drew last, which is
        // the old one until the editor has laid out the new text.
        cx.spawn(async move |this, cx| {
            smol::Timer::after(std::time::Duration::from_millis(32)).await;
            let _ = this.update(cx, |_, cx| cx.notify());
        })
        .detach();
        if let Some(autocomplete) = crate::autocomplete::global(cx) {
            autocomplete.update(cx, |autocomplete, cx| {
                autocomplete.practice_changed(before, after, cx)
            });
        }
    }

    /// A key in the practice editor, by the same rules as a live field: the
    /// primary key wins when both are the same. True when it took the key.
    fn practice_key(
        &mut self,
        key: InterceptedKey,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let keys = AcceptKeys::from_settings(&self.data.read(cx).settings);
        match keys.is_full(key) {
            Some(whole) => self.practice_accept(whole, window, cx),
            None => false,
        }
    }

    /// One accept, or "Insert suggestion" with `whole`. True when it took the key.
    fn practice_accept(
        &mut self,
        whole: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        let Some(autocomplete) = crate::autocomplete::global(cx) else {
            return false;
        };
        let Some(edit) = autocomplete.update(cx, |autocomplete, cx| {
            autocomplete.practice_accept(whole, cx)
        }) else {
            return false;
        };
        self.practice.update(cx, |state, cx| {
            if edit.backward == 0 && edit.forward == 0 {
                state.insert(edit.text, window, cx);
                return;
            }
            // Replace the `:shortcode` an emoji stands for, or the rest of
            // the word the caret is inside of.
            let value = state.value();
            let cursor = state.cursor().min(value.len());
            let (before, after) = value.split_at(cursor);
            let (back, forward) = replaced_bytes(before, after, edit.backward, edit.forward);
            state.set_selected_range(cursor - back..cursor + forward, cx);
            state.replace(edit.text, window, cx);
        });
        self.practice_sync(cx);
        true
    }

    fn practice_dismiss(&mut self, cx: &mut Context<Self>) -> bool {
        crate::autocomplete::global(cx).is_some_and(|autocomplete| {
            autocomplete.update(cx, |autocomplete, cx| autocomplete.practice_dismiss(cx))
        })
    }

    pub(super) fn writing_sections(&mut self, cx: &mut Context<Self>) -> Vec<Section> {
        let (settings, model_ready, downloads, installed, ocr_ready) = {
            let data = self.data.read(cx);
            (
                data.settings.clone(),
                data.models.autocomplete_ready,
                data.downloads.clone(),
                data.models.installed.clone(),
                data.models.screen_text_ready,
            )
        };
        let (support, limitation, ghost, learning, memory_use, server_problem, rehearsal) =
            match crate::autocomplete::global(cx) {
                Some(autocomplete) => {
                    let autocomplete = autocomplete.read(cx);
                    (
                        autocomplete.support().clone(),
                        autocomplete.limitation(),
                        autocomplete.practice.ghost(&settings),
                        autocomplete.learning.clone(),
                        autocomplete.memory_use.clone(),
                        autocomplete.server_problem.clone(),
                        autocomplete.rehearsal.clone(),
                    )
                }
                None => (
                    Support::Available,
                    None,
                    None,
                    Default::default(),
                    Default::default(),
                    None,
                    None,
                ),
            };
        let route = server::route(&settings, None);
        let uses_server = settings.cotyping_backend != CotypingBackend::OnDevice;
        // Why the selected server's last request brought no suggestion, shown
        // only for the server it belongs to.
        let server_failure = match &route {
            Route::Server(endpoint) => server_problem
                .as_ref()
                .filter(|problem| problem.identity == endpoint.identity())
                .map(writing_server::failure_text),
            _ => None,
        };
        let setup_problem = match &route {
            Route::Unavailable(problem) => Some(writing_server::problem_text(problem)),
            _ => None,
        };
        let lb = cx.lb().clone();
        let data = self.data.clone();
        let model_name = writing_server::model_display_name(&settings);
        let needs = models::autocomplete_needs(&settings);
        let missing: Vec<String> = needs
            .iter()
            .filter(|id| !installed.contains(id))
            .cloned()
            .collect();
        let downloading = needs
            .iter()
            .find_map(|id| downloads.get(id))
            .map(|d| d.fraction());
        let other_apps = support == Support::Available;

        // Summary: what autocomplete is doing, its readiness and the switch.
        let summary_detail = if settings.cotyping_enabled && other_apps {
            lokalbot_i18n::format(
                "{model_name} · suggestions appear as you type in other apps.",
                &[("model_name", model_name.to_string())],
            )
        } else if settings.cotyping_enabled {
            lokalbot_i18n::format(
                "{model_name} · suggestions appear in the practice editor below.",
                &[("model_name", model_name.to_string())],
            )
        } else if uses_server && model_ready {
            lokalbot_i18n::tr("The server is ready. Turn on autocomplete to start.").into()
        } else if uses_server {
            lokalbot_i18n::tr("Finish the server setup under Where autocomplete runs to try it.")
                .into()
        } else if model_ready {
            lokalbot_i18n::tr("The model is ready. Turn on autocomplete to start.").into()
        } else {
            lokalbot_i18n::tr("Download the Autocomplete model to try it.").into()
        };
        let readiness: AnyElement = match (model_ready, downloading) {
            _ if server_failure.is_some() => {
                status_pill(lokalbot_i18n::tr("Server problem"), false, cx).into_any_element()
            }
            _ if uses_server && model_ready => {
                status_pill(lokalbot_i18n::tr("Server ready"), true, cx).into_any_element()
            }
            _ if uses_server => {
                status_pill(lokalbot_i18n::tr("Server setup needed"), false, cx).into_any_element()
            }
            (true, _) => status_pill(lokalbot_i18n::tr("Model ready"), true, cx).into_any_element(),
            (false, Some(fraction)) => status_pill_text(
                lokalbot_i18n::format(
                    "Downloading · {0}%",
                    &[("0", format!("{}", (fraction * 100.).round()))],
                ),
                false,
                cx,
            )
            .into_any_element(),
            (false, None) => {
                let size = models::size_label(
                    missing
                        .iter()
                        .map(|id| models::model_bytes(id, &settings))
                        .sum(),
                );
                let download_data = data.clone();
                let ids = missing.clone();
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(status_pill(lokalbot_i18n::tr("Model needed"), false, cx))
                    .child(
                        Button::new("settings-cotyping-download")
                            .outline()
                            .small()
                            .icon(Icon::new(Ico::CircleArrowDown))
                            .label(lokalbot_i18n::format(
                                "Download · {size}",
                                &[("size", size.to_string())],
                            ))
                            .on_click(move |_, _, cx| {
                                download_data.update(cx, |data, cx| {
                                    for id in &ids {
                                        data.request(AppEvent::DownloadModel(id.clone()), cx);
                                    }
                                })
                            }),
                    )
                    .into_any_element()
            }
        };
        let enable_data = data.clone();
        let summary = h_flex()
            .w_full()
            .gap(px(12.))
            .items_start()
            .child(ui::icon_tile(
                Ico::TextCursorInput,
                if settings.cotyping_enabled {
                    lb.accent_text
                } else {
                    lb.text_tertiary
                },
                px(40.),
            ))
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
                            .child(if settings.cotyping_enabled {
                                lokalbot_i18n::tr("Autocomplete on")
                            } else {
                                lokalbot_i18n::tr("Autocomplete off")
                            }),
                    )
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(summary_detail),
                    )
                    .child(h_flex().pt(px(2.)).child(readiness)),
            )
            .child(settings_row::switch(
                "settings.cotypingEnabled",
                settings.cotyping_enabled,
                move |on, _, cx| {
                    enable_data.update(cx, |data, cx| {
                        data.update_settings(|s| s.cotyping_enabled = on, cx)
                    })
                },
            ));
        let mut home = Section::new(None).row(
            "settings.cotypingEnabled",
            settings_row::content_row(
                "settings.cotypingEnabled",
                summary,
                self.is_focused("settings.cotypingEnabled"),
                cx,
            ),
        );
        if let Some(problem) = setup_problem.as_ref().filter(|_| uses_server) {
            home = home.row(
                "settings.autocompleteServerSetup",
                settings_row::content_row(
                    "settings.autocompleteServerSetup",
                    notice(Ico::TriangleAlert, problem.clone(), lb.text_secondary, cx),
                    false,
                    cx,
                ),
            );
        } else if let Some(failure) = &server_failure {
            home = home.row(
                "settings.autocompleteServerProblem",
                settings_row::content_row(
                    "settings.autocompleteServerProblem",
                    notice(Ico::TriangleAlert, failure.clone(), lb.attention_text, cx),
                    false,
                    cx,
                ),
            );
        }
        // Where autocomplete cannot follow the user into other apps, say so.
        if let Support::Unavailable(reason) = &support {
            home = home.row(
                "settings.autocompleteSupport",
                settings_row::content_row(
                    "settings.autocompleteSupport",
                    notice(Ico::TriangleAlert, reason.clone(), lb.attention_text, cx),
                    false,
                    cx,
                ),
            );
        } else if let Some(limitation) = limitation
            && settings.cotyping_enabled
        {
            home = home.row(
                "settings.autocompleteLimitation",
                settings_row::content_row(
                    "settings.autocompleteLimitation",
                    notice(Ico::Info, limitation, lb.text_secondary, cx),
                    false,
                    cx,
                ),
            );
        }

        let inventory = self.context_inventory(cx);
        let rehearsal_sources = writing_rehearsal::statuses(
            &visible_text_state(&settings, other_apps),
            &meeting_memory_state(&settings, &inventory),
            &screen_memory_state(&settings, &inventory),
            rehearsal.as_ref(),
        );
        let empty_answer = rehearsal
            .as_ref()
            .and_then(|rehearsal| rehearsal.suppression)
            .filter(|_| ghost.is_none());
        // The practice editor, through the same engine path as other apps.
        let conversation =
            v_flex()
                .gap(px(6.))
                .child(
                    div()
                        .text_size(ty::SECONDARY)
                        .font_weight(FontWeight::SEMIBOLD)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                            "Sample conversation",
                        ))),
                )
                .children(crate::autocomplete::PRACTICE_CONVERSATION.iter().map(
                    |(sender, text)| {
                        h_flex()
                            .gap(px(6.))
                            .px(px(10.))
                            .py(px(6.))
                            .rounded(px(8.))
                            .bg(lb.text.opacity(0.05))
                            .text_size(ty::SECONDARY)
                            .child(
                                div()
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text)
                                    .child(*sender),
                            )
                            .child(div().text_color(lb.text).child(*text))
                    },
                ));
        let hint = accept_hint(&settings);
        let editor = div()
            .relative()
            .w_full()
            .capture_action(cx.listener(|this, _: &IndentInline, window, cx| {
                let taken = this.practice_key(InterceptedKey::Tab, window, cx);
                log::debug!("autocomplete: practice Tab, accepted: {taken}");
                // Without a ghost to accept, this short editor follows the
                // window's focus order instead of inserting indentation.
                if !taken {
                    window.focus_next(cx);
                }
                cx.stop_propagation();
            }))
            .capture_action(cx.listener(|_, _: &OutdentInline, window, cx| {
                window.focus_prev(cx);
                cx.stop_propagation();
            }))
            .capture_action(cx.listener(|this, _: &MoveRight, window, cx| {
                if this.practice_key(InterceptedKey::RightArrow, window, cx) {
                    cx.stop_propagation();
                } else if let Some(autocomplete) = crate::autocomplete::global(cx) {
                    // Like the live monitor, an arrow drops the suggestion even
                    // when the caret has nowhere further to go.
                    autocomplete.update(cx, |autocomplete, cx| autocomplete.practice_drop(cx));
                }
            }))
            .capture_key_down(cx.listener(|this, event: &KeyDownEvent, window, cx| {
                let modifiers = event.keystroke.modifiers;
                if event.keystroke.key == "`"
                    && !modifiers.control
                    && !modifiers.alt
                    && !modifiers.platform
                    && !modifiers.shift
                    && this.practice_key(InterceptedKey::Backtick, window, cx)
                {
                    cx.stop_propagation();
                }
            }))
            .capture_action(cx.listener(|this, _: &InputEscape, _, cx| {
                let taken = this.practice_dismiss(cx);
                log::debug!("autocomplete: practice Esc, dismissed: {taken}");
                if taken {
                    cx.stop_propagation();
                }
            }))
            .child(Textarea::new(&self.practice).h(px(96.)).text_size(ty::BODY))
            .child({
                // Where the editor is on screen, for placing the ghost in it.
                let origin = self.practice_origin.clone();
                canvas(
                    move |bounds, _, _| origin.set(Some(bounds.origin)),
                    |_, _, _, _| {},
                )
                .absolute()
                .top_0()
                .left_0()
                .size_full()
            })
            .when_some(self.practice_ghost(ghost.clone(), cx), |this, ghost| {
                this.child(ghost)
            });
        let has_ghost = ghost.is_some();
        let practice = v_flex()
            .w_full()
            .gap(px(10.))
            .child(conversation)
            .child(editor)
            .child(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(hint),
                    )
                    .child(
                        Button::new("settings-insert-suggestion")
                            .primary()
                            .small()
                            .label(lokalbot_i18n::tr("Insert suggestion"))
                            .disabled(!has_ghost)
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.practice_accept(true, window, cx);
                            })),
                    ),
            )
            .child(settings_row::help(
                if !settings.cotyping_enabled {
                    lokalbot_i18n::tr("Turn on autocomplete to see suggestions while you type.")
                } else if !model_ready && uses_server {
                    lokalbot_i18n::tr("Suggestions appear here as grey text once the server setup is finished.")
                } else if !model_ready {
                    lokalbot_i18n::tr("Suggestions appear here as grey text once the Autocomplete model is downloaded.")
                } else if uses_server {
                    lokalbot_i18n::tr("Type in the reply, or put the cursor at the end of the text. Suggestions come from the server you chose.")
                } else {
                    lokalbot_i18n::tr("Type in the reply, or put the cursor at the end of the text. Suggestions come from the Autocomplete model on this PC.")
                },
                cx,
            ))
            .when_some(empty_answer, |this, reason| {
                this.child(writing_rehearsal::explanation_line(reason, cx))
            })
            .child(writing_rehearsal::render(&rehearsal_sources, cx));
        let usage_timing = self.usage_timing(cx);
        let try_it = Section::new(lokalbot_i18n::tr("Try the real autocomplete"))
            .row(
                "settings.autocompletePreview",
                settings_row::content_row(
                    "settings.autocompletePreview",
                    practice,
                    self.is_focused("settings.autocompletePreview"),
                    cx,
                ),
            )
            .row(
                "settings.autocompleteUsage",
                settings_row::content_row("settings.autocompleteUsage", usage_timing, false, cx),
            );

        let words = settings.cotyping_max_words.clamp(2, 50);
        let words_data = data.clone();
        let change_data = data.clone();
        let autocomplete = Section::new(lokalbot_i18n::tr("Autocomplete"))
            .row(
                "settings.cotypingModel",
                settings_row::row(
                    "settings.cotypingModel",
                    lokalbot_i18n::tr("Autocomplete model"),
                    None,
                    h_flex()
                        .gap(px(10.))
                        .items_center()
                        .child(
                            div()
                                .text_size(ty::BODY)
                                .text_color(lb.text_secondary)
                                .child(model_name.clone()),
                        )
                        .child(
                            Button::new("settings-cotyping-model")
                                .outline()
                                .small()
                                .label(lokalbot_i18n::tr("Change…"))
                                .on_click(move |_, _, cx| {
                                    change_data.update(cx, |data, cx| {
                                        data.open_settings(SettingsCategory::Models, cx)
                                    });
                                }),
                        ),
                    false,
                    cx,
                ),
            )
            .row(
                "settings.cotypingMaxWords",
                settings_row::row(
                    "settings.cotypingMaxWords",
                    lokalbot_i18n::format(
                        "Suggestion length: up to {words} words",
                        &[("words", format!("{}", words))],
                    ),
                    None,
                    settings_row::stepper(
                        "settings-cotyping-words",
                        "",
                        words > 2,
                        words < 50,
                        move |step, _, cx| {
                            let next = (words as i32 + step).clamp(2, 50) as u32;
                            words_data.update(cx, |data, cx| {
                                data.update_settings(|s| s.cotyping_max_words = next, cx)
                            });
                        },
                        cx,
                    ),
                    self.is_focused("settings.cotypingMaxWords"),
                    cx,
                ),
            )
            .row(
                "settings.cotypingMultiLine",
                self.toggle(
                    "settings.cotypingMultiLine",
                    lokalbot_i18n::tr("Allow multi-line suggestions"),
                    None,
                    settings.cotyping_multi_line,
                    |s, v| s.cotyping_multi_line = v,
                    cx,
                ),
            )
            .row(
                "settings.cotypingDebounceMs",
                settings_row::row(
                    "settings.cotypingDebounceMs",
                    lokalbot_i18n::tr("Pause before suggesting"),
                    None,
                    h_flex()
                        .gap(px(10.))
                        .items_center()
                        .child(div().w(px(220.)).child(Slider::new(&self.debounce_slider)))
                        .child(
                            div()
                                .min_w(px(56.))
                                .text_size(ty::BODY)
                                .text_color(lb.text_secondary)
                                .flex()
                                .justify_end()
                                .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                                    "{0} ms",
                                    &[("0", format!("{}", settings.cotyping_debounce_ms))],
                                ))),
                        ),
                    self.is_focused("settings.cotypingDebounceMs"),
                    cx,
                ),
            )
            .row(
                "settings.cotypingAcceptGranularity",
                self.choice(
                    "settings.cotypingAcceptGranularity",
                    lokalbot_i18n::tr("Each accept takes"),
                    None,
                    vec![
                        (
                            AcceptGranularity::Word,
                            granularity_label(AcceptGranularity::Word).into(),
                        ),
                        (
                            AcceptGranularity::Phrase,
                            granularity_label(AcceptGranularity::Phrase).into(),
                        ),
                    ],
                    settings.cotyping_accept_granularity,
                    |s, v| s.cotyping_accept_granularity = v,
                    cx,
                ),
            )
            .row(
                "settings.cotypingAcceptKey",
                self.choice(
                    "settings.cotypingAcceptKey",
                    lokalbot_i18n::tr("Accept next"),
                    None,
                    [CotypingAcceptKey::Tab, CotypingAcceptKey::RightArrow]
                        .map(|key| (key, accept_key_label(key).into()))
                        .to_vec(),
                    settings.cotyping_accept_key,
                    |s, v| s.cotyping_accept_key = v,
                    cx,
                ),
            )
            .row(
                "settings.cotypingFullAcceptKey",
                self.choice(
                    "settings.cotypingFullAcceptKey",
                    lokalbot_i18n::tr("Accept the rest"),
                    None,
                    [
                        CotypingFullAcceptKey::Backtick,
                        CotypingFullAcceptKey::RightArrow,
                        CotypingFullAcceptKey::Off,
                    ]
                    .map(|key| (key, full_accept_key_label(key).into()))
                    .to_vec(),
                    settings.cotyping_full_accept_key,
                    |s, v| s.cotyping_full_accept_key = v,
                    cx,
                ),
            )
            .row(
                "settings.cotypingAutoAcceptTrailingPunctuation",
                self.toggle(
                    "settings.cotypingAutoAcceptTrailingPunctuation",
                    lokalbot_i18n::tr("Accept punctuation with the word"),
                    Some(lokalbot_i18n::tr("When off, a full stop or comma after a word takes its own press, so you can still end the sentence differently.")),
                    settings.cotyping_auto_accept_trailing_punctuation,
                    |s, v| s.cotyping_auto_accept_trailing_punctuation = v,
                    cx,
                ),
            )
            .row(
                "settings.cotypingAddSpaceAfterAccept",
                self.toggle(
                    "settings.cotypingAddSpaceAfterAccept",
                    lokalbot_i18n::tr("Add a space after accepting a word"),
                    None,
                    settings.cotyping_add_space_after_accept,
                    |s, v| s.cotyping_add_space_after_accept = v,
                    cx,
                ),
            )
            .row(
                "settings.cotypingEscapeBehavior",
                self.choice(
                    "settings.cotypingEscapeBehavior",
                    lokalbot_i18n::tr("Escape on a suggestion"),
                    Some(lokalbot_i18n::tr("Pausing keeps Escape from also reaching the app and holds suggestions in that field for a few seconds. Escape is never touched when no suggestion is showing.").into()),
                    [CotypingEscapeBehavior::Pause, CotypingEscapeBehavior::PassThrough]
                        .map(|behavior| (behavior, escape_label(behavior).into()))
                        .to_vec(),
                    settings.cotyping_escape_behavior,
                    |s, v| s.cotyping_escape_behavior = v,
                    cx,
                ),
            )
            .row(
                "settings.cotypingSuggestInIntegratedTerminals",
                self.toggle(
                    "settings.cotypingSuggestInIntegratedTerminals",
                    lokalbot_i18n::tr("Suggest in integrated terminals"),
                    None,
                    settings.cotyping_suggest_in_integrated_terminals,
                    |s, v| s.cotyping_suggest_in_integrated_terminals = v,
                    cx,
                ),
            )
            .row(
                "settings.cotypingMatchHostStyle",
                self.toggle(
                    "settings.cotypingMatchHostStyle",
                    lokalbot_i18n::tr("Match the app font and text color"),
                    None,
                    settings.cotyping_match_host_style,
                    |s, v| s.cotyping_match_host_style = v,
                    cx,
                ),
            )
            .row(
                "settings.cotypingAutocorrect",
                self.toggle(
                    "settings.cotypingAutocorrect",
                    lokalbot_i18n::tr("Autocorrect the current word"),
                    Some(if lokalbot_platform::autocomplete::spell::has_dictionaries() {
                        lokalbot_i18n::tr("Offers a one-key correction for the word you are typing.")
                    } else {
                        lokalbot_i18n::tr("Needs a spelling dictionary on this computer, such as a Hunspell dictionary package for your language.")
                    }),
                    settings.cotyping_autocorrect,
                    |s, v| s.cotyping_autocorrect = v,
                    cx,
                ),
            )
            .row(
                "settings.cotypingEmoji",
                self.toggle(
                    "settings.cotypingEmoji",
                    lokalbot_i18n::tr("Emoji autocomplete"),
                    Some(lokalbot_i18n::tr("Complete :shortcode: emoji.")),
                    settings.cotyping_emoji,
                    |s, v| s.cotyping_emoji = v,
                    cx,
                ),
            )
            .row(
                "settings.cotypingMacros",
                self.toggle(
                    "settings.cotypingMacros",
                    lokalbot_i18n::tr("Macros"),
                    Some(lokalbot_i18n::tr("Complete /macros such as math, dates, units, and currency.")),
                    settings.cotyping_macros,
                    |s, v| s.cotyping_macros = v,
                    cx,
                ),
            );

        let visible_state = visible_text_state(&settings, other_apps);
        let window_state = window_text_state(&settings, other_apps, ocr_ready);
        let meeting_state = meeting_memory_state(&settings, &inventory);
        let screen_state = screen_memory_state(&settings, &inventory);
        let mut context = Section::new(lokalbot_i18n::tr("Context"));
        if server::leaves_this_computer(&settings)
            && let Some(host) = server::configured_host(&settings)
        {
            context = context.row(
                "settings.cotypingContextDestination",
                settings_row::content_row(
                    "settings.cotypingContextDestination",
                    notice(
                        Ico::Network,
                        lokalbot_i18n::format(
                            "Context you turn on here is sent to {0} with what you type.",
                            &[("0", host)],
                        ),
                        lb.text_secondary,
                        cx,
                    ),
                    false,
                    cx,
                ),
            );
        }
        let context = context
            .row(
                "settings.cotypingUseAppContext",
                self.toggle(
                    "settings.cotypingUseAppContext",
                    lokalbot_i18n::tr("Use app and window context"),
                    None,
                    settings.cotyping_use_app_context,
                    |s, v| s.cotyping_use_app_context = v,
                    cx,
                ),
            )
            .row(
                "settings.cotypingUseClipboard",
                self.toggle(
                    "settings.cotypingUseClipboard",
                    lokalbot_i18n::tr("Use clipboard as temporary context"),
                    None,
                    settings.cotyping_use_clipboard,
                    |s, v| s.cotyping_use_clipboard = v,
                    cx,
                ),
            )
            .row(
                "settings.cotypingUseVisibleContext",
                self.toggle(
                    "settings.cotypingUseVisibleContext",
                    lokalbot_i18n::tr("Use visible text above the field"),
                    Some(
                        lokalbot_i18n::tr("Use nearby messages and labels to suggest relevant replies. Processed on this PC, never saved; capture exclusions apply and private browser windows are skipped."),
                    ),
                    settings.cotyping_use_visible_context,
                    |s, v| s.cotyping_use_visible_context = v,
                    cx,
                ),
            )
;
        let context = with_state(
            context,
            "settings.cotypingUseVisibleContextState",
            &visible_state,
            cx,
        );
        let context = context
            .row(
                "settings.cotypingUseWindowText",
                self.toggle(
                    "settings.cotypingUseWindowText",
                    lokalbot_i18n::tr("Use the focused window as context"),
                    Some(lokalbot_i18n::tr("Read the whole window you are typing in with on-device text recognition, so suggestions follow the full conversation or page. The image and text stay on this computer and are never saved; capture exclusions apply and private browser windows are skipped. The recognition model reads Latin script.")),
                    settings.cotyping_use_window_text,
                    |s, v| s.cotyping_use_window_text = v,
                    cx,
                ),
            )
;
        let context = if window_state == ContextState::Off {
            context
        } else {
            context.row(
                "settings.cotypingUseWindowTextState",
                self.window_text_row(&window_state, ocr_ready, &downloads, cx),
            )
        };
        let context = context
            .row(
                "settings.cotypingUseMeetingMemory",
                self.toggle(
                    "settings.cotypingUseMeetingMemory",
                    lokalbot_i18n::tr("Use meeting and work memory"),
                    Some(
                        lokalbot_i18n::tr("Use up to two relevant facts from recent meeting notes, decisions, and work memory to help with names and details. Processed on this PC."),
                    ),
                    settings.cotyping_use_meeting_memory,
                    |s, v| s.cotyping_use_meeting_memory = v,
                    cx,
                ),
            )
;
        let context = with_state(
            context,
            "settings.cotypingUseMeetingMemoryState",
            &meeting_state,
            cx,
        );
        let context = context
            .row(
                "settings.cotypingUseScreenMemory",
                self.toggle(
                    "settings.cotypingUseScreenMemory",
                    lokalbot_i18n::tr("Use screen-derived work memory"),
                    Some(lokalbot_i18n::tr("Also allow relevant work memory derived from screen activity and daily journals. Reads what is already saved; it does not capture new screens or start an overnight review. Mixed meeting and screen memories require both settings.")),
                    settings.cotyping_use_screen_memory,
                    |s, v| s.cotyping_use_screen_memory = v,
                    cx,
                ),
            )
            ;
        let context = with_state(
            context,
            "settings.cotypingUseScreenMemoryState",
            &screen_state,
            cx,
        );
        let memory_use_text = if !memory_use.0.is_empty() {
            Some(lokalbot_i18n::format(
                "Last suggestion used: {0}",
                &[("0", memory_use.0.join(", "))],
            ))
        } else if memory_use.1 {
            Some(lokalbot_i18n::tr("Last suggestion: no relevant memory found.").to_string())
        } else {
            None
        };
        let context = match memory_use_text {
            Some(text) => context.row(
                "settings.cotypingMemoryUse",
                settings_row::content_row(
                    "settings.cotypingMemoryUse",
                    settings_row::help(text, cx),
                    false,
                    cx,
                ),
            ),
            None => context,
        };

        let learning_message = if learning.forgetting {
            None
        } else {
            match learning.forgotten {
                Some(true) => Some(lokalbot_i18n::tr("Learned text deleted.")),
                Some(false) => Some(lokalbot_i18n::tr(
                    "Could not delete learned text. Please try again.",
                )),
                None => None,
            }
        };
        let examples = settings.cotyping_learning_examples_in_prompt.clamp(1, 5);
        let examples_data = data.clone();
        let profile = Section::new(lokalbot_i18n::tr("Writing profile"))
            .row(
                "settings.cotypingUserName",
                settings_row::row(
                    "settings.cotypingUserName",
                    lokalbot_i18n::tr("Your name"),
                    Some(lokalbot_i18n::tr("Also keeps you out of People.").into()),
                    div()
                        .w(px(280.))
                        .child(Input::new(&self.cotyping_name).small()),
                    self.is_focused("settings.cotypingUserName"),
                    cx,
                ),
            )
            .row(
                "settings.cotypingStyleNote",
                settings_row::row(
                    "settings.cotypingStyleNote",
                    lokalbot_i18n::tr("Writing style"),
                    None,
                    div()
                        .w(px(280.))
                        .child(Input::new(&self.cotyping_style).small()),
                    self.is_focused("settings.cotypingStyleNote"),
                    cx,
                ),
            )
            .row(
                "settings.cotypingLanguages",
                settings_row::row(
                    "settings.cotypingLanguages",
                    lokalbot_i18n::tr("Languages"),
                    None,
                    div()
                        .w(px(280.))
                        .child(Input::new(&self.writing.languages).small()),
                    self.is_focused("settings.cotypingLanguages"),
                    cx,
                ),
            )
            .row(
                "settings.cotypingExtendedContext",
                settings_row::row(
                    "settings.cotypingExtendedContext",
                    lokalbot_i18n::tr("Notes for autocomplete"),
                    None,
                    div()
                        .w(px(280.))
                        .child(Textarea::new(&self.writing.notes).h(px(72.))),
                    self.is_focused("settings.cotypingExtendedContext"),
                    cx,
                ),
            )
            .row(
                "settings.cotypingUseLocalLearning",
                self.toggle(
                    "settings.cotypingUseLocalLearning",
                    lokalbot_i18n::tr("Learn locally from accepted completions"),
                    Some(lokalbot_i18n::tr("Kept for 30 days and reused only in the same identified document. Mail, chat, unknown documents, and preview runs are excluded.")),
                    settings.cotyping_use_local_learning,
                    |s, v| s.cotyping_use_local_learning = v,
                    cx,
                ),
            )
            .row(
                "settings.cotypingLearningExamplesInPrompt",
                settings_row::row(
                    "settings.cotypingLearningExamplesInPrompt",
                    lokalbot_i18n::tr("Learned examples per suggestion"),
                    None,
                    settings_row::stepper(
                        "settings-cotyping-learned-examples",
                        examples.to_string(),
                        examples > 1,
                        examples < 5,
                        move |step, _, cx| {
                            let next = (examples as i32 + step).clamp(1, 5) as u32;
                            examples_data.update(cx, |data, cx| {
                                data.update_settings(
                                    |s| s.cotyping_learning_examples_in_prompt = next,
                                    cx,
                                )
                            });
                        },
                        cx,
                    ),
                    self.is_focused("settings.cotypingLearningExamplesInPrompt"),
                    cx,
                ),
            )
            .row(
                "settings.cotypingForgetLearned",
                settings_row::content_row(
                    "settings.cotypingForgetLearned",
                    v_flex()
                        .w_full()
                        .gap(px(6.))
                        .when_some(learning.problem.clone(), |this, problem| {
                            this.child(notice(Ico::TriangleAlert, problem, lb.attention_text, cx))
                        })
                        .child(
                            h_flex().child(
                                Button::new("settings-forget-learned")
                                    .outline()
                                    .small()
                                    .label(if learning.forgetting {
                                        lokalbot_i18n::tr("Forgetting…")
                                    } else {
                                        lokalbot_i18n::tr("Forget learned text")
                                    })
                                    .disabled(learning.forgetting)
                                    .on_click(move |_, _, cx| {
                                        crate::bridge::send(
                                            Command::Autocomplete(AutocompleteCommand::ForgetLearned),
                                            cx,
                                        );
                                    }),
                            ),
                        )
                        .when_some(learning_message, |this, message| {
                            this.child(settings_row::help(message, cx))
                        }),
                    false,
                    cx,
                ),
            )
            .row(
                "settings.writingProfileHelp",
                settings_row::content_row(
                    "settings.writingProfileHelp",
                    settings_row::help(
                        lokalbot_i18n::tr("Autocomplete and Compose dictation write as you, in this style. Both are optional and stay on this PC unless your Think model runs on a server."),
                        cx,
                    ),
                    false,
                    cx,
                ),
            );

        let exclusions = Section::new(lokalbot_i18n::tr("Exclusions"))
            .row(
                "settings.cotypingExcludedApps",
                settings_row::content_row(
                    "settings.cotypingExcludedApps",
                    self.cotyping_excluded_apps.clone(),
                    self.is_focused("settings.cotypingExcludedApps"),
                    cx,
                ),
            )
            .row(
                "settings.cotypingExcludedDomains",
                settings_row::content_row(
                    "settings.cotypingExcludedDomains",
                    self.cotyping_excluded_sites.clone(),
                    self.is_focused("settings.cotypingExcludedDomains"),
                    cx,
                ),
            )
            .row(
                "settings.cotypingExclusionsHelp",
                settings_row::content_row(
                    "settings.cotypingExclusionsHelp",
                    settings_row::help(
                        lokalbot_i18n::tr("Password managers, password fields and terminals are always skipped. Autocomplete never reads an excluded app or site."),
                        cx,
                    ),
                    false,
                    cx,
                ),
            );

        let server_section = self.server_section(cx);
        let mut sections = vec![home, try_it, server_section, autocomplete, context, profile];
        if let Some(statistics) = self.statistics_section(cx) {
            sections.push(statistics);
        }
        sections.push(exclusions);
        sections
    }

    /// Counted once in a while, not per redraw: facts come from a file.
    fn context_inventory(&mut self, cx: &mut Context<Self>) -> Inventory {
        if let Some((at, inventory)) = self.writing.inventory
            && at.elapsed() < INVENTORY_LIFETIME
        {
            return inventory;
        }
        let data = self.data.read(cx);
        let now = chrono::Utc::now();
        let max_age = memory::max_age();
        let mut inventory = Inventory {
            recent_meetings: data
                .meetings
                .iter()
                .filter(|m| {
                    m.is_own_work() && m.ended_at.is_some() && now - m.started_at <= max_age
                })
                .count(),
            ..Inventory::default()
        };
        let items = lokalbot_core::evidence::read_work_memory(data.library.paths().root())
            .map(|bytes| memory::work_memory_items(&bytes))
            .unwrap_or_default();
        for item in items {
            let age = now - item.updated_at;
            if age < chrono::Duration::seconds(-60) || age > max_age {
                continue;
            }
            match (item.requires_meetings, item.requires_screen_memory) {
                (true, true) => inventory.mixed_facts += 1,
                (true, false) => inventory.meeting_facts += 1,
                (false, true) => inventory.screen_facts += 1,
                (false, false) => {}
            }
        }
        self.writing.inventory = Some((std::time::Instant::now(), inventory));
        inventory
    }

    /// The window text grant's state, with the download it needs: never
    /// started on its own.
    fn window_text_row(
        &self,
        state: &ContextState,
        ocr_ready: bool,
        downloads: &std::collections::HashMap<String, crate::state::DownloadProgress>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let id = "settings.cotypingUseWindowTextState";
        let ocr = lokalbot_ai::ocr::OCR_MODEL_ID;
        let offer = matches!(state, ContextState::Unavailable(_))
            && !ocr_ready
            && self.data.read(cx).settings.cotyping_enabled;
        let row = h_flex().w_full().gap(px(10.)).items_center().child(
            div()
                .flex_1()
                .min_w_0()
                .child(context_state_line(state, cx)),
        );
        let row = if offer {
            let data = self.data.clone();
            let progress = downloads.get(ocr).map(|d| d.fraction());
            row.child(
                Button::new("settings-cotyping-window-download")
                    .outline()
                    .small()
                    .icon(Icon::new(Ico::CircleArrowDown))
                    .label(match progress {
                        Some(fraction) => lokalbot_i18n::format(
                            "Downloading · {0}%",
                            &[("0", format!("{}", (fraction * 100.).round()))],
                        ),
                        None => lokalbot_i18n::format(
                            "Download · {size}",
                            &[(
                                "size",
                                models::size_label(lokalbot_ai::ocr::total_size()).to_string(),
                            )],
                        ),
                    })
                    .disabled(progress.is_some())
                    .on_click(move |_, _, cx| {
                        data.update(cx, |data, cx| {
                            data.request(AppEvent::DownloadModel(ocr.to_string()), cx)
                        })
                    }),
            )
        } else {
            row
        };
        settings_row::content_row(id, row, false, cx).into_any_element()
    }

    /// The practice suggestion after the editor's caret: inline at the end
    /// of a line, else under the caret's line, as in other apps. Placed in
    /// the editor from the caret it drew last, so scrolling clips it.
    fn practice_ghost(&self, ghost: Option<(String, usize)>, cx: &App) -> Option<AnyElement> {
        let (text, emphasis) = ghost?;
        let (caret, line_height) = self.practice.read(cx).cursor_layout()?;
        let origin = self.practice_origin.get()?;
        let (x, y) = (caret.origin.x - origin.x, caret.origin.y - origin.y);
        let lb = cx.lb();
        let display =
            lokalbot_platform::autocomplete::geometry::display_text(&text).replace('\n', " ");
        let split = display
            .char_indices()
            .nth(emphasis)
            .map_or(display.len(), |(index, _)| index);
        let (strong, rest) = display.split_at(split);
        let visible = |text: &str| SharedString::from(text.replace(' ', "\u{a0}"));
        let at_line_end = self.practice_text.1.is_empty() || self.practice_text.1.starts_with('\n');
        let spans = h_flex()
            .h(line_height)
            .items_center()
            .whitespace_nowrap()
            .font_family(crate::theme::FONT_FAMILY)
            .text_size(ty::BODY)
            .child(div().text_color(lb.text_secondary).child(visible(strong)))
            .child(div().text_color(lb.text_tertiary).child(visible(rest)));
        let ghost = if at_line_end {
            div()
                .absolute()
                .left(x + caret.size.width)
                .top(y)
                .child(spans)
        } else {
            div()
                .absolute()
                .left(x)
                .top(y + caret.size.height + px(2.))
                .px(px(8.))
                .py(px(2.))
                .rounded(px(7.))
                .bg(lb.elevated)
                .border_1()
                .border_color(lb.separator)
                .shadow_sm()
                .child(spans)
        };
        Some(ghost.into_any_element())
    }
}

/// A context source's effective state, under its switch; nothing while it is off.
fn with_state(section: Section, id: &'static str, state: &ContextState, cx: &mut App) -> Section {
    if *state == ContextState::Off {
        return section;
    }
    let line = context_state_line(state, cx);
    section.row(id, settings_row::content_row(id, line, false, cx))
}

fn context_state_line(state: &ContextState, cx: &App) -> gpui_kit::Div {
    let lb = cx.lb();
    match state {
        ContextState::Off => div(),
        ContextState::Available(message) => {
            notice(Ico::Check, message.clone(), lb.text_secondary, cx)
        }
        ContextState::NothingSaved(message) => {
            notice(Ico::Info, message.clone(), lb.text_secondary, cx)
        }
        ContextState::Unavailable(message) => {
            notice(Ico::TriangleAlert, message.clone(), lb.attention_text, cx)
        }
    }
}

/// A warning or note under the summary.
fn notice(
    icon: Ico,
    text: impl Into<SharedString>,
    color: gpui_kit::Hsla,
    _cx: &App,
) -> gpui_kit::Div {
    h_flex()
        .w_full()
        .gap(px(8.))
        .items_start()
        .child(div().pt(px(1.)).child(ui::icon(icon, px(14.), color)))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .text_size(ty::SECONDARY)
                .text_color(color)
                .child(text.into()),
        )
}

/// "Model ready" in green or "Model needed" in amber (`MemoryHealthStatus`).
pub fn status_pill(label: &'static str, good: bool, cx: &App) -> gpui_kit::Div {
    status_pill_text(label, good, cx)
}

fn status_pill_text(label: impl Into<SharedString>, good: bool, cx: &App) -> gpui_kit::Div {
    let lb = cx.lb();
    let tint = if good {
        lb.success_text
    } else {
        lb.attention_text
    };
    h_flex()
        .gap(px(5.))
        .items_center()
        .px(px(8.))
        .py(px(2.))
        .rounded_full()
        .bg(tint.opacity(0.10))
        .text_size(ty::CAPTION)
        .font_weight(FontWeight::MEDIUM)
        .text_color(tint)
        .child(ui::status_dot(tint, px(6.)))
        .child(label.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_hint_follows_the_keys() {
        let mut settings = Settings::default();
        assert_eq!(
            accept_hint(&settings),
            "Tab accepts the next word · ` accepts the rest · Esc dismisses"
        );
        settings.cotyping_accept_granularity = AcceptGranularity::Phrase;
        settings.cotyping_full_accept_key = CotypingFullAcceptKey::Off;
        assert_eq!(
            accept_hint(&settings),
            "Tab accepts the next phrase · Esc dismisses"
        );
        // The primary key wins when both are the same key.
        settings.cotyping_accept_key = CotypingAcceptKey::RightArrow;
        settings.cotyping_full_accept_key = CotypingFullAcceptKey::RightArrow;
        assert_eq!(
            accept_hint(&settings),
            "Right Arrow accepts the next phrase · Esc dismisses"
        );
    }

    #[test]
    fn context_states_say_why_a_grant_cannot_work() {
        let mut settings = Settings {
            cotyping_enabled: true,
            ..Settings::default()
        };
        assert!(matches!(
            window_text_state(&settings, true, true),
            ContextState::Available(_)
        ));
        assert!(matches!(
            window_text_state(&settings, true, false),
            ContextState::Unavailable(_)
        ));
        settings.cotyping_use_window_text = false;
        assert_eq!(window_text_state(&settings, true, true), ContextState::Off);

        settings.cotyping_use_screen_memory = true;
        let mixed = Inventory {
            mixed_facts: 2,
            ..Inventory::default()
        };
        assert!(matches!(
            screen_memory_state(&settings, &mixed),
            ContextState::Unavailable(_)
        ));
        settings.cotyping_use_meeting_memory = true;
        assert!(matches!(
            screen_memory_state(&settings, &mixed),
            ContextState::Available(_)
        ));
        assert!(matches!(
            meeting_memory_state(&settings, &Inventory::default()),
            ContextState::NothingSaved(_)
        ));
    }
}
