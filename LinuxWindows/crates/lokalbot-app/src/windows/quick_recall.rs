//! Quick Recall (`QuickRecallView.swift`): the window Ctrl+K and the
//! system-wide shortcut open. Type to search meetings, screen history, files
//! and agent notes, run a command, or ask. Results are grouped by kind, three
//! of each with Show all. Return opens the selected row; Ctrl+Return asks, and
//! the answer shows here with numbered sources and Continue in main window.
//! Before anything is typed it lists recent items and every command. Escape
//! or leaving the window closes it.

mod answer;
mod model;
mod rows;

use std::collections::HashSet;
use std::time::Duration;

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Escape, Input, InputEvent, InputState, MoveDown, MoveUp};
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Bounds, Context, Entity, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, Render, ScrollHandle, StatefulInteractiveElement as _,
    Styled as _, Subscription, Task, Window, WindowBounds, WindowKind, WindowOptions, div, px,
    size,
};
use lokalbot_core::ScreenMoment;
use uuid::Uuid;

use self::answer::{AnswerEvent, QuickRecallAnswer};
use self::model::{Cursor, Found, Group, GroupKind, Target};
use self::rows::{Destination, RowModel};
use crate::i18n::h_flex;
use crate::pages::ask::search;
use crate::pages::ask::{open_screen_moment, stop_answer_speech};
use crate::palette;
use crate::state::{AppData, AppEvent, AskRequest, MeetingTab, Section};
use crate::theme::{LbThemeExt as _, UiFont as _, ty};
use crate::ui::screen_thumbnail::ScreenThumbnails;
use crate::ui::{self, Ico};
use crate::windows::screen_image::ScreenImage;

/// The window (`QuickRecallView.size`).
const WIDTH: f32 = 660.;
const HEIGHT: f32 = 512.;

/// Opens Quick Recall from the system-wide shortcut, the tray or the command
/// line, or brings the open window forward with its text selected.
pub fn open(cx: &mut App) {
    open_from(false, cx);
}

/// Ctrl+K. Opened from the main window, the window also offers the commands
/// of the page it shows (`quickRecallOpenedFromMainWindow`). Pressing it again
/// inside the window keeps what it was opened from.
pub fn open_from_shortcut(cx: &mut App) {
    let main = crate::desktop::desktop(cx).and_then(|desktop| *desktop.main_window.lock());
    let from_main = main.is_some() && cx.active_window() == main;
    open_from(from_main, cx);
}

fn open_from(from_main_window: bool, cx: &mut App) {
    let existing = super::secondary(cx).quick_recall;
    if super::activate(existing, cx) {
        let view = super::secondary(cx)
            .quick_recall_view
            .clone()
            .and_then(|view| view.upgrade());
        if let (Some(handle), Some(view)) = (existing, view) {
            let _ = handle.update(cx, |_, window, cx| {
                view.update(cx, |view, cx| view.focus_input(window, cx))
            });
        }
        return;
    }
    let bounds = Bounds::centered(None, size(px(WIDTH), px(HEIGHT)), cx);
    let options = |kind| WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        titlebar: None,
        focus: true,
        show: true,
        kind,
        is_resizable: false,
        is_minimizable: false,
        app_id: Some(lokalbot_platform::APP_ID.into()),
        #[cfg(target_os = "linux")]
        window_decorations: Some(gpui_kit::WindowDecorations::Client),
        ..Default::default()
    };
    // Windows takes a borderless, topmost tool window; X11 only gives
    // keyboard focus to managed windows, so Linux uses a normal one.
    let window_kind = || {
        if cfg!(target_os = "windows") {
            WindowKind::PopUp
        } else {
            WindowKind::Normal
        }
    };
    // On Wayland, a centered layer surface that takes the keyboard: a tiling
    // compositor would otherwise split the screen with it.
    #[cfg(target_os = "linux")]
    let layer = super::layer_surface(
        "lokalbot-quick-recall",
        gpui_kit::layer_shell::Anchor::empty(),
        None,
        gpui_kit::layer_shell::KeyboardInteractivity::Exclusive,
    );
    #[cfg(not(target_os = "linux"))]
    let layer: Option<WindowKind> = None;
    let build = move |window: &mut Window, cx: &mut App| {
        window.set_window_title(lokalbot_i18n::tr("Quick Recall"));
        let view = cx.new(|cx| QuickRecall::new(from_main_window, window, cx));
        view.update(cx, |view, cx| view.focus_input(window, cx));
        view
    };
    let opened = match layer {
        Some(kind) => gpui_kit::open_window(options(kind), cx, build).or_else(|err| {
            log::debug!("Quick Recall: no layer shell, opening a window: {err:#}");
            gpui_kit::open_window(options(window_kind()), cx, build)
        }),
        None => gpui_kit::open_window(options(window_kind()), cx, build),
    };
    match opened {
        Ok((handle, view)) => {
            let windows = super::secondary(cx);
            windows.quick_recall = Some(handle);
            windows.quick_recall_view = Some(view.downgrade());
        }
        Err(err) => log::error!("could not open Quick Recall: {err:#}"),
    }
}

pub struct QuickRecall {
    data: Entity<AppData>,
    input: Entity<InputState>,
    query: String,
    /// Opened with Ctrl+K from the main window: the commands of its page are
    /// offered too.
    in_workspace: bool,
    results: search::Results,
    saved: Vec<ScreenMoment>,
    cursor: Cursor,
    /// Groups whose heading was asked to list everything here (commands).
    expanded: HashSet<GroupKind>,
    searching: bool,
    search_task: Option<Task<()>>,
    /// Ctrl+Return arrived while a word's matches were still being found.
    pending_question: Option<String>,
    scroll: ScrollHandle,
    was_active: bool,
    thumbnails: ScreenThumbnails,
    /// The answer showing in place of the results.
    answer: Option<Entity<QuickRecallAnswer>>,
    /// The search that led to the answer, for the back arrow.
    recalled_query: String,
    copied: bool,
    _answer_subscriptions: Vec<Subscription>,
    _subscriptions: Vec<Subscription>,
}

impl QuickRecall {
    fn new(in_workspace: bool, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let data = AppData::global(cx);
        let input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                "Search, ask, or run a command",
                window,
                cx,
            ))
        });
        let subscriptions = vec![
            cx.subscribe_in(
                &input,
                window,
                |this, input, event: &InputEvent, window, cx| match event {
                    InputEvent::Change => {
                        let value = input.read(cx).value().to_string();
                        if value != this.query {
                            this.query = value;
                            if this.answer.is_none() {
                                if this.pending_question.as_deref() != Some(this.trimmed()) {
                                    this.pending_question = None;
                                }
                                this.expanded.clear();
                                this.search(window, cx);
                            }
                        }
                    }
                    InputEvent::PressEnter { secondary, .. } => {
                        if *secondary || this.answer.is_some() {
                            let question = this.trimmed().to_string();
                            this.ask(question, window, cx);
                        } else {
                            this.submit(window, cx);
                        }
                    }
                    _ => {}
                },
            ),
            cx.observe_in(&data, window, |this, data, window, cx| {
                // A question asked elsewhere moves the window to its answer.
                let streaming = data
                    .read(cx)
                    .ask_stream
                    .as_ref()
                    .filter(|stream| stream.error.is_none())
                    .map(|s| s.conversation_id);
                if let Some(id) = streaming
                    && this
                        .answer
                        .as_ref()
                        .is_some_and(|answer| answer.read(cx).conversation_id() != id)
                {
                    this.show_answer(id, None, window, cx);
                }
                cx.notify();
            }),
            cx.observe_window_activation(window, |this, window, cx| {
                if window.is_window_active() {
                    this.was_active = true;
                } else if this.was_active {
                    // Like the macOS panel, leaving Quick Recall dismisses it.
                    this.close(window, cx);
                }
            }),
        ];
        // The answer already being written, as on the Mac.
        let responding = data
            .read(cx)
            .ask_stream
            .as_ref()
            .filter(|stream| stream.error.is_none())
            .map(|stream| stream.conversation_id);
        let mut view = Self {
            data,
            input,
            query: String::new(),
            in_workspace,
            results: search::Results::default(),
            saved: Vec::new(),
            cursor: Cursor::default(),
            expanded: HashSet::new(),
            searching: false,
            search_task: None,
            pending_question: None,
            scroll: ScrollHandle::new(),
            was_active: false,
            thumbnails: ScreenThumbnails::default(),
            answer: None,
            recalled_query: String::new(),
            copied: false,
            _answer_subscriptions: Vec::new(),
            _subscriptions: subscriptions,
        };
        view.load_saved(cx);
        match responding {
            Some(id) => view.show_answer(id, None, window, cx),
            None => {
                let count = view.selectable_count(cx);
                view.cursor.reset(count);
            }
        }
        view
    }

    fn set_placeholder(
        &mut self,
        placeholder: &'static str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.input.update(cx, |input, cx| {
            input.set_placeholder(lokalbot_i18n::tr(placeholder), window, cx)
        });
    }

    fn focus_input(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.input.update(cx, |input, cx| {
            input.focus(window, cx);
            input.select_all(window, cx);
        });
    }

    fn set_query(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.query = text.to_string();
        self.input.update(cx, |input, cx| {
            input.set_value(text.to_string(), window, cx)
        });
    }

    fn load_saved(&mut self, cx: &mut Context<Self>) {
        let library = self.data.read(cx).library.clone();
        cx.spawn(async move |this, cx| {
            let saved = cx
                .background_spawn(async move { library.saved_moments().unwrap_or_default() })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.saved = saved.into_iter().take(model::SAVED_MOMENTS).collect();
                if this.trimmed().is_empty() && this.answer.is_none() {
                    let count = this.selectable_count(cx);
                    this.cursor.reset(count);
                }
                cx.notify();
            });
        })
        .detach();
    }

    fn trimmed(&self) -> &str {
        self.query.trim()
    }

    // ---------------------------------------------------------------- rows

    /// Every command, those of the main window's page included when it was
    /// opened from there.
    fn commands(&self, cx: &App) -> Vec<palette::PaletteCommand> {
        palette::commands(self.data.read(cx), self.in_workspace, cx)
    }

    /// The groups on show (`QuickRecallContent.groups`).
    fn groups(&self, cx: &App) -> Vec<Group<RowModel>> {
        if self.answer.is_some() {
            return Vec::new();
        }
        let data = self.data.read(cx);
        let query = self.trimmed();
        if query.is_empty() {
            // The newest meetings; one merged into another is listed by it.
            let meetings = data
                .meetings
                .iter()
                .filter(|meeting| !meeting.is_merged_source())
                .take(model::RECENT_LIMIT)
                .map(|meeting| (meeting.started_at, RowModel::recent_meeting(meeting)))
                .collect();
            let saved = self
                .saved
                .iter()
                .take(model::RECENT_LIMIT)
                .map(|moment| (moment.ts, RowModel::screen(moment, None)))
                .collect();
            let commands = palette::idle_order(self.commands(cx))
                .into_iter()
                .map(RowModel::command)
                .collect();
            return model::idle(
                model::recent(meetings, saved, model::RECENT_LIMIT),
                commands,
            );
        }
        let (leading, loose) = palette::split(&self.commands(cx), query);
        let found = Found {
            commands: leading.into_iter().map(RowModel::command).collect(),
            loose_commands: loose.into_iter().map(RowModel::command).collect(),
            meetings: self
                .results
                .meetings
                .iter()
                .map(RowModel::meeting)
                .collect(),
            screens: search::screens_with_saved_first(&self.results.screens, &self.saved)
                .iter()
                .map(RowModel::screen_result)
                .collect(),
            files: self.results.files.iter().map(RowModel::file).collect(),
            agent_notes: self.results.notes.iter().map(RowModel::note).collect(),
            truncated: self.results.truncated,
            screen_source_count: self.results.screens.len(),
            ..Found::default()
        };
        model::groups(
            found,
            &self.expanded,
            data.settings.coding_agent_notes_enabled,
        )
    }

    fn row_count(&self, cx: &App) -> usize {
        self.groups(cx).iter().map(|group| group.rows.len()).sum()
    }

    /// Rows Return may land on as a list appears (`model::selectable_rows`).
    fn selectable_count(&self, cx: &App) -> usize {
        model::selectable_rows(&self.groups(cx))
    }

    fn has_ask_row(&self) -> bool {
        self.answer.is_none() && !self.trimmed().is_empty()
    }

    fn has_memory_matches(&self) -> bool {
        !self.results.meetings.is_empty()
            || !self.results.screens.is_empty()
            || !self.results.files.is_empty()
            || !self.results.notes.is_empty()
    }

    // -------------------------------------------------------------- search

    fn search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let text = self.trimmed().to_string();
        self.results = search::Results::default();
        if self.answer.is_some() || text.is_empty() {
            self.searching = false;
            self.search_task = None;
            self.pending_question = None;
            let count = self.selectable_count(cx);
            self.cursor.reset(count);
            cx.notify();
            return;
        }
        self.searching = true;
        // Matching commands are listed at once; Return runs the first.
        let count = self.selectable_count(cx);
        self.cursor.reset(count);
        let (library, meetings, file_folders, agent_notes) = {
            let data = self.data.read(cx);
            (
                data.library.clone(),
                data.meetings.clone(),
                if data.settings.file_search_enabled {
                    data.settings.file_search_folders.clone()
                } else {
                    Vec::new()
                },
                data.settings.coding_agent_notes_enabled,
            )
        };
        let query = search::Query {
            text: text.clone(),
            meetings: true,
            screen: true,
            file_folders,
            agent_notes,
            limit: search::DISPLAY_LIMIT,
            ..Default::default()
        };
        self.search_task = Some(cx.spawn_in(window, async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(120))
                .await;
            let (lexical_library, lexical_query, lexical_meetings) =
                (library.clone(), query.clone(), meetings.clone());
            let found = cx
                .background_spawn(async move {
                    search::run(&lexical_library, &lexical_meetings, &lexical_query)
                })
                .await;
            let mut refined = found.clone();
            let _ = this.update_in(cx, |this, window, cx| {
                if this.trimmed() != text || this.answer.is_some() {
                    return;
                }
                this.results = found;
                this.searching = false;
                let count = this.selectable_count(cx);
                this.cursor.reset(count);
                cx.notify();
                if this.pending_question.as_deref() == Some(text.as_str()) {
                    this.ask(text.clone(), window, cx);
                }
            });
            if !query.wants_meaning() {
                return;
            }
            // Meaning second, so words show at once.
            let refined = cx
                .background_spawn(async move {
                    let vector = lokalbot_engine::query_vector(query.text.trim())?;
                    search::refine(&library, &query, &vector, &mut refined);
                    search::fuse_meetings(&library, &meetings, &query, &vector, &mut refined);
                    Some((query.text, refined))
                })
                .await;
            if let Some((text, refined)) = refined {
                let _ = this.update(cx, |this, cx| {
                    if this.trimmed() == text && this.answer.is_none() {
                        this.results = refined;
                        cx.notify();
                    }
                });
            }
        }));
        cx.notify();
    }

    // ---------------------------------------------------------------- keys

    /// Up and Down go round the rows and the Ask row. Inside an answer the
    /// field keeps them.
    fn move_selection(&mut self, offset: isize, cx: &mut Context<Self>) -> bool {
        if self.answer.is_some() {
            return false;
        }
        let count = self.row_count(cx);
        self.cursor.move_by(offset, count, self.has_ask_row());
        if let Some(Target::Row(index)) = self.cursor.target(count, self.has_ask_row()) {
            self.scroll.scroll_to_item(index);
        }
        cx.notify();
        true
    }

    /// Return opens the selected row; on the Ask row it asks.
    fn submit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let groups = self.groups(cx);
        let rows = rows::flatten(&groups);
        match self.cursor.target(rows.len(), self.has_ask_row()) {
            Some(Target::Row(index)) => {
                let destination = rows[index].destination.clone();
                self.run(destination, window, cx);
            }
            Some(Target::Ask) => {
                let question = self.trimmed().to_string();
                self.ask(question, window, cx);
            }
            None => {}
        }
    }

    fn run(&mut self, destination: Destination, window: &mut Window, cx: &mut Context<Self>) {
        match destination {
            // Recording and dictation act on the app the person came from,
            // which gets the keyboard back as this window closes.
            Destination::Command(command) => {
                self.close(window, cx);
                cx.defer(move |cx| palette::run(&command, cx));
                return;
            }
            Destination::Screen(moment) => open_screen_moment(&self.data, &moment, cx),
            Destination::Meeting { id, at } => {
                let tab = if at.is_some() {
                    MeetingTab::Transcript
                } else {
                    MeetingTab::Summary
                };
                self.data
                    .update(cx, |data, cx| data.open_meeting(id, tab, at, cx));
            }
            Destination::RecentMeeting(id) => self.data.update(cx, |data, cx| {
                data.open_meeting(id, Default::default(), None, cx)
            }),
            // Files open in their own app, not in LokalBot's main window.
            Destination::File(hit) => {
                search::open_file(&hit);
                self.close(window, cx);
                return;
            }
            // A note opens the agent's own file.
            Destination::Note(hit) => {
                search::open_note(&hit);
                self.close(window, cx);
                return;
            }
        }
        super::activate_main(cx);
        self.close(window, cx);
    }

    /// "Show all N": commands list here; a kind of result opens Ask on this
    /// search, where every match of every kind is listed.
    fn show_all(&mut self, kind: GroupKind, window: &mut Window, cx: &mut Context<Self>) {
        if !kind.opens_ask() {
            let count = self.row_count(cx);
            let on_ask = self.cursor.target(count, self.has_ask_row()) == Some(Target::Ask);
            self.expanded.insert(kind);
            if on_ask {
                let count = self.row_count(cx);
                self.cursor.select(Target::Ask, count);
            }
            cx.notify();
            return;
        }
        let question = self.trimmed().to_string();
        self.data.update(cx, |data, cx| {
            data.ask(
                AskRequest {
                    question,
                    meeting_ids: Vec::new(),
                    submit: false,
                    day: None,
                },
                cx,
            )
        });
        super::activate_main(cx);
        self.close(window, cx);
    }

    // -------------------------------------------------------------- asking

    fn is_remember_statement(&self, text: &str, cx: &App) -> bool {
        self.data.read(cx).settings.ask_memory_enabled
            && lokalbot_core::personal::remember_statement(text).is_some()
    }

    fn responding(&self, cx: &App) -> bool {
        self.data
            .read(cx)
            .ask_stream
            .as_ref()
            .is_some_and(|stream| stream.error.is_none())
    }

    /// Asks here. From the results this starts a new conversation; inside an
    /// answer it is a follow-up within the scope of the question before it.
    fn ask(&mut self, question: String, window: &mut Window, cx: &mut Context<Self>) {
        let value = question.trim().to_string();
        if value.is_empty() {
            return;
        }
        if self.responding(cx) {
            // An answer is already being written (asked here or in the main
            // window): show it instead of dropping the key.
            let streaming = self
                .data
                .read(cx)
                .ask_stream
                .as_ref()
                .map(|s| s.conversation_id);
            if let (None, Some(id)) = (&self.answer, streaming) {
                self.recalled_query = value;
                self.show_answer(id, None, window, cx);
            }
            return;
        }
        if let Some(answer) = self.answer.clone() {
            // Until the question before it is known, nothing is sent.
            let Some(scope) = answer.read(cx).follow_up_scope() else {
                return;
            };
            let id = answer.read(cx).conversation_id();
            let saved = scope.saved.clone();
            self.data
                .update(cx, |data, cx| data.ask_question(id, value, scope, None, cx));
            answer.update(cx, |answer, cx| answer.asked(saved, cx));
            self.set_query("", window, cx);
            self.copied = false;
            cx.notify();
            return;
        }
        let remembers = self.is_remember_statement(&value, cx);
        // A word or short phrase is answered from its matches, so it waits for
        // them. A full question does not depend on what is listed.
        if self.searching && !remembers && !model::is_full_question(&value) {
            self.pending_question = Some(value);
            // Show that the key was taken while the matches arrive.
            let count = self.row_count(cx);
            self.cursor.select(Target::Ask, count);
            cx.notify();
            return;
        }
        self.pending_question = None;
        let scope = model::ask_scope(
            &value,
            self.results.meetings.iter().map(|g| g.meeting.id).collect(),
            self.results.screens.iter().map(|s| s.moment.id).collect(),
            remembers,
        );
        let id = Uuid::new_v4();
        self.recalled_query = value.clone();
        self.show_answer(id, Some(scope.saved.clone()), window, cx);
        self.data
            .update(cx, |data, cx| data.ask_question(id, value, scope, None, cx));
    }

    fn show_answer(
        &mut self,
        id: Uuid,
        asked: Option<lokalbot_core::QuestionScope>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.search_task = None;
        self.searching = false;
        self.pending_question = None;
        let answer = cx.new(|cx| QuickRecallAnswer::new(id, asked, cx));
        self._answer_subscriptions = vec![
            cx.observe(&answer, |_, _, cx| cx.notify()),
            cx.subscribe_in(
                &answer,
                window,
                |this, _, event: &AnswerEvent, window, cx| match event {
                    AnswerEvent::Opened { in_main_window } => {
                        if *in_main_window {
                            super::activate_main(cx);
                        }
                        this.close(window, cx);
                    }
                },
            ),
        ];
        self.answer = Some(answer);
        self.copied = false;
        self.set_placeholder("Ask a follow-up", window, cx);
        self.set_query("", window, cx);
        self.focus_input(window, cx);
        cx.notify();
    }

    /// The back arrow: the results, with the search that led to the answer.
    fn show_recall(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.answer = None;
        self._answer_subscriptions.clear();
        self.set_placeholder("Search, ask, or run a command", window, cx);
        let query = self.recalled_query.clone();
        self.set_query(&query, window, cx);
        self.load_saved(cx);
        self.search(window, cx);
        self.focus_input(window, cx);
    }

    /// Both windows share the conversation; opening it never asks again.
    fn continue_in_main_window(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(id) = self.answer.as_ref().map(|a| a.read(cx).conversation_id()) else {
            return;
        };
        self.data.update(cx, |data, cx| {
            data.ask_open_conversation = Some(id);
            data.navigate(Section::Ask, cx)
        });
        super::activate_main(cx);
        self.close(window, cx);
    }

    fn copy_answer(&mut self, text: String, cx: &mut Context<Self>) {
        cx.write_to_clipboard(gpui_kit::ClipboardItem::new_string(text));
        self.copied = true;
        cx.notify();
        cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(1500))
                .await;
            let _ = this.update(cx, |this, cx| {
                this.copied = false;
                cx.notify();
            });
        })
        .detach();
    }

    fn close(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.search_task = None;
        stop_answer_speech(cx);
        self.thumbnails.clear(window, cx);
        let windows = super::secondary(cx);
        windows.quick_recall = None;
        windows.quick_recall_view = None;
        window.remove_window();
    }

    // ------------------------------------------------------------- drawing

    /// The field, in the window's top bar.
    fn render_field(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let in_answer = self.answer.is_some();
        let responding = in_answer && self.responding(cx);
        h_flex()
            .h(px(58.))
            .flex_none()
            .gap(px(12.))
            .items_center()
            .pl(px(18.))
            .pr(px(16.))
            .map(|this| {
                if in_answer {
                    this.child(
                        Button::new("quick-recall-back")
                            .ghost()
                            .w(px(28.))
                            .h(px(30.))
                            .icon(ui::icon(Ico::ChevronLeft, px(20.), lb.accent_text))
                            .tooltip(lokalbot_i18n::tr("Back to results"))
                            .on_click(
                                cx.listener(|this, _, window, cx| this.show_recall(window, cx)),
                            ),
                    )
                } else {
                    this.child(
                        div()
                            .w(px(24.))
                            .flex_none()
                            .flex()
                            .justify_center()
                            .child(ui::icon(Ico::Search, px(20.), lb.accent_text)),
                    )
                }
            })
            .child(
                div().flex_1().min_w_0().child(
                    Input::new(&self.input)
                        .appearance(false)
                        .text_size(px(22.))
                        .line_height(px(30.))
                        .h(px(36.))
                        .px_0(),
                ),
            )
            .when(responding, |this| {
                let data = self.data.clone();
                this.child(
                    Button::new("quick-recall-stop")
                        .ghost()
                        .small()
                        .icon(Icon::new(Ico::CircleStop))
                        .tooltip(lokalbot_i18n::tr("Stop answer"))
                        .on_click(move |_, _, cx| {
                            data.update(cx, |data, cx| data.request(AppEvent::StopAnswer, cx))
                        }),
                )
            })
            .when(!responding && !self.query.is_empty(), |this| {
                this.child(
                    Button::new("quick-recall-clear")
                        .ghost()
                        .small()
                        .icon(Icon::new(Ico::CircleX))
                        .tooltip(lokalbot_i18n::tr("Clear"))
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.set_query("", window, cx);
                            if this.answer.is_none() {
                                this.expanded.clear();
                                this.search(window, cx);
                            }
                            this.focus_input(window, cx);
                        })),
                )
            })
    }

    fn render_results(&self, groups: &[Group<RowModel>], cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let row_count: usize = groups.iter().map(|group| group.rows.len()).sum();
        let selected = self.cursor.target(row_count, self.has_ask_row());
        // The scroll handle reveals rows by child index, so a group's heading
        // is drawn inside its first row's element.
        let mut elements: Vec<AnyElement> = Vec::new();
        let mut index = 0;
        for group in groups {
            for (position, row) in group.rows.iter().enumerate() {
                let image = match &row.lead {
                    rows::Lead::Thumbnail(moment) => {
                        self.thumbnails
                            .image(moment, cx, |view: &QuickRecall| &view.thumbnails)
                    }
                    _ => None,
                }
                .filter(|image| matches!(image, ScreenImage::Ready(_)));
                let destination = row.destination.clone();
                let kind = group.kind;
                elements.push(
                    v_flex()
                        .w_full()
                        .when(position == 0, |this| {
                            this.child(rows::group_header(
                                group,
                                cx.listener(move |this, _, window, cx| {
                                    this.show_all(kind, window, cx)
                                }),
                                cx,
                            ))
                        })
                        .child(
                            div().px(px(8.)).child(
                                rows::row(row, selected == Some(Target::Row(index)), image, cx)
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        this.run(destination.clone(), window, cx)
                                    })),
                            ),
                        )
                        .into_any_element(),
                );
                index += 1;
            }
        }
        if self.searching {
            elements.push(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .px(px(20.))
                    .py(px(12.))
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(Spinner::new().xsmall().color(lb.text_secondary))
                    .child(ui::text::paragraph(lokalbot_i18n::tr(
                        "Searching your local memory…",
                    )))
                    .into_any_element(),
            );
        } else if !self.trimmed().is_empty() && !self.has_memory_matches() {
            elements.push(self.render_no_matches(row_count > 0, cx));
        }
        div()
            .id("quick-recall-results")
            .size_full()
            .overflow_y_scroll()
            .track_scroll(&self.scroll)
            .child(v_flex().w_full().pb(px(6.)).children(elements))
            .into_any_element()
    }

    /// Nothing in memory matched. Under matching commands it is one quiet
    /// line; alone it also says what was searched.
    fn render_no_matches(&self, beside_commands: bool, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let color = if beside_commands {
            lb.text_secondary
        } else {
            lb.text
        };
        v_flex()
            .w_full()
            .gap(px(6.))
            .px(px(20.))
            .py(px(if beside_commands { 12. } else { 24. }))
            .when(!beside_commands, |this| this.items_center())
            .child(
                h_flex()
                    .gap(px(6.))
                    .items_center()
                    .child(ui::icon(Ico::Search, px(13.), color))
                    .child(
                        div()
                            .text_size(if beside_commands {
                                ty::SECONDARY
                            } else {
                                ty::SECTION
                            })
                            .when(!beside_commands, |this| {
                                this.font_weight(FontWeight::SEMIBOLD)
                            })
                            .text_color(color)
                            .child(lokalbot_i18n::tr("No local matches")),
                    ),
            )
            .when(!beside_commands, |this| {
                this.child(
                    div()
                        .max_w(px(460.))
                        .text_center()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(ui::text::paragraph(lokalbot_i18n::tr(
                            "Nothing in saved moments, captured screens, or meetings matches this search.",
                        ))),
                )
            })
            .into_any_element()
    }

    /// Pinned under the results. Ctrl+Return asks from anywhere in the window.
    fn render_ask_row(&self, row_count: usize, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let query = self.trimmed().to_string();
        let place = model::place(&self.data.read(cx).settings);
        let reads_listed = model::reads_listed_matches(
            &query,
            !self.results.meetings.is_empty() || !self.results.screens.is_empty(),
            self.searching,
            self.is_remember_statement(&query, cx),
        );
        let detail = model::ask_row_detail(&place, reads_listed);
        let selected = self.cursor.target(row_count, true) == Some(Target::Ask);
        div()
            .px(px(8.))
            .py(px(4.))
            .child(
                rows::ask_row(&query, &detail, selected, cx).on_click(cx.listener(
                    move |this, _, window, cx| {
                        let question = this.trimmed().to_string();
                        this.ask(question, window, cx)
                    },
                )),
            )
    }

    /// The foot of an answer: where it was answered and what it read, Copy,
    /// and the way into the full Ask screen (`QuickRecallAnswerFoot`).
    fn render_answer_foot(
        &self,
        answer: &Entity<QuickRecallAnswer>,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let place = model::place(&self.data.read(cx).settings);
        let (latest, receipt, scope) = {
            let answer = answer.read(cx);
            (
                answer.latest_answer(cx),
                answer.ends_with_receipt(),
                answer.scope_label(cx),
            )
        };
        let label = model::answer_foot_label(&place, latest.is_some(), scope.as_deref());
        let icon = match place {
            model::Place::OnDevice => Ico::Lock,
            model::Place::Remote(_) => Ico::Globe,
            model::Place::Blocked => Ico::TriangleAlert,
        };
        let icon_color = if place == model::Place::Blocked {
            lb.attention_text
        } else {
            lb.text_secondary
        };
        let copied = self.copied;
        h_flex()
            .min_h(px(46.))
            .flex_none()
            .gap(px(8.))
            .items_center()
            .pl(px(22.))
            .pr(px(12.))
            // A "Remember …" receipt was saved here without any model.
            .when(!receipt, |this| {
                this.child(ui::icon(icon, px(12.), icon_color)).child(
                    div()
                        .flex_1()
                        .min_w_0()
                        .truncate()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(label),
                )
            })
            .when(receipt, |this| this.child(div().flex_1()))
            .when_some(latest, |this, text| {
                this.child(
                    Button::new("quick-recall-copy")
                        .ghost()
                        .small()
                        .icon(Icon::new(if copied { Ico::Check } else { Ico::Copy }))
                        .disabled(copied)
                        .tooltip(if copied {
                            lokalbot_i18n::tr("Copied")
                        } else {
                            lokalbot_i18n::tr("Copy this answer")
                        })
                        .on_click(
                            cx.listener(move |this, _, _, cx| this.copy_answer(text.clone(), cx)),
                        ),
                )
            })
            .child(
                Button::new("quick-recall-continue")
                    .outline()
                    .small()
                    .label(lokalbot_i18n::tr("Continue in main window"))
                    .on_click(
                        cx.listener(|this, _, window, cx| this.continue_in_main_window(window, cx)),
                    ),
            )
    }
}

impl Render for QuickRecall {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.thumbnails.drop_released(window, cx);
        let lb = cx.lb().clone();
        let groups = self.groups(cx);
        let row_count: usize = groups.iter().map(|group| group.rows.len()).sum();
        let body = match self.answer.clone() {
            Some(answer) => v_flex()
                .flex_1()
                .min_h_0()
                .child(div().flex_1().min_h_0().child(answer.clone()))
                .child(ui::divider(cx))
                .child(self.render_answer_foot(&answer, cx))
                .into_any_element(),
            None => v_flex()
                .flex_1()
                .min_h_0()
                .child(
                    div()
                        .flex_1()
                        .min_h_0()
                        .child(self.render_results(&groups, cx)),
                )
                .when(self.has_ask_row(), |this| {
                    this.child(ui::divider(cx))
                        .child(self.render_ask_row(row_count, cx))
                })
                .into_any_element(),
        };
        v_flex()
            .size_full()
            .key_context("QuickRecall")
            .ui_font()
            .text_align(crate::i18n::interface_alignment())
            .bg(lb.elevated)
            .text_color(lb.text)
            .capture_action(cx.listener(|this, _: &MoveUp, _, cx| {
                if this.move_selection(-1, cx) {
                    cx.stop_propagation();
                }
            }))
            .capture_action(cx.listener(|this, _: &MoveDown, _, cx| {
                if this.move_selection(1, cx) {
                    cx.stop_propagation();
                }
            }))
            .on_action(cx.listener(|this, _: &Escape, window, cx| this.close(window, cx)))
            .child(self.render_field(cx))
            .child(ui::divider(cx))
            .child(body)
    }
}
