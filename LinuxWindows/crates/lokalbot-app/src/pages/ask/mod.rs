//! Ask (`AskView.swift`, `ChatView.swift`): saved conversations on the left;
//! on the right an empty state, keyword results while typing, or the
//! conversation, with the composer docked at the bottom.

mod composer;
mod history;

pub use composer::inference as composer_inference;
pub(crate) use history::row_timestamp;
mod results;
pub mod scope;
pub mod search;
mod transcript;

use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::time::Duration;

use crate::i18n::h_flex;
use gpui_kit::component::calendar::{CalendarEvent, CalendarState, Date};
use gpui_kit::component::input::{InputEvent, InputState, TextareaState};
use gpui_kit::component::v_flex;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    App, AppContext as _, Context, Entity, InteractiveElement as _, IntoElement, KeyBinding,
    ParentElement as _, Render, ScrollHandle, SharedString, Styled as _, Subscription, Task,
    Window, actions, div,
};
use lokalbot_core::{ChatRole, Conversation};
use uuid::Uuid;

use self::scope::{DateScope, Sources};
use self::search::{Facet, MeetingGroup, ScreenResult};
use crate::pages::Page;
use crate::state::{AppData, AppEvent, AskRequest, MeetingTab, Section};
use crate::theme::LbThemeExt as _;
use crate::ui::answer_text::Answer;

actions!(ask, [NewConversation]);

const KEY_CONTEXT: &str = "Ask";

pub fn bind_keys(cx: &mut App) {
    cx.bind_keys([KeyBinding::new(
        "ctrl-n",
        NewConversation,
        Some(KEY_CONTEXT),
    )]);
}

/// Keyword results for the text in the composer.
#[derive(Default)]
struct Results {
    /// The query these results belong to.
    query: String,
    running: bool,
    meetings: Vec<MeetingGroup>,
    screens: Vec<ScreenResult>,
    truncated: bool,
    selected: usize,
    /// Arrow keys picked a row, so Return opens it even for a question.
    picked_with_keyboard: bool,
    expanded: HashSet<Uuid>,
}

impl Results {
    /// Meeting groups and screen moments, in list order.
    fn count(&self) -> usize {
        self.meetings.len() + self.screens.len()
    }
}

/// Opens a screen moment from Ask or Quick Recall in Timeline
/// (`ScreenMomentDetailView`).
pub fn open_screen_moment(
    data: &Entity<AppData>,
    moment: &lokalbot_core::ScreenMoment,
    cx: &mut App,
) {
    let (id, ts) = (moment.id, moment.ts);
    data.update(cx, |data, cx| data.open_screen_moment(id, ts, cx));
}

/// Per-message disclosure and feedback state in the conversation.
#[derive(Default)]
struct TurnState {
    /// Evidence disclosures the user opened or closed (default: open for ≤ 3 citations).
    evidence: HashMap<Uuid, bool>,
    worked: HashSet<Uuid>,
    questions: HashSet<Uuid>,
    copied: Option<Uuid>,
    answers: HashMap<Uuid, (u64, Rc<Answer>)>,
}

pub struct AskPage {
    data: Entity<AppData>,
    conversations: Vec<Conversation>,
    conversations_loaded: bool,
    loaded_revision: Option<u64>,
    /// The conversation on screen; `None` is a new, empty conversation.
    selected: Option<Uuid>,
    history_input: Entity<InputState>,
    history_query: String,
    composer: Entity<TextareaState>,
    query: String,
    sources: Sources,
    date_scope: DateScope,
    facet: Facet,
    /// Evidence boundary from "Ask This Meeting" or from asking about results.
    meeting_scope: Option<Vec<Uuid>>,
    /// A question asked while its search was still running.
    pending_question: Option<String>,
    /// The "Answer sources" disclosure above the composer.
    sources_expanded: bool,
    date_picker: Entity<CalendarState>,
    picked_day: Option<chrono::NaiveDate>,
    results: Results,
    search_task: Option<Task<()>>,
    turns: TurnState,
    /// Screen moments the answers cite, loaded on demand.
    screen_citations: crate::ui::citations::ScreenCitations,
    loading_screen_citations: HashSet<i64>,
    transcript_scroll: ScrollHandle,
    results_scroll: ScrollHandle,
    history_scroll: ScrollHandle,
    /// Keep the conversation pinned to its end while an answer streams.
    follow_stream: bool,
    last_section: Section,
    last_stream_len: usize,
    _subscriptions: Vec<Subscription>,
}

/// What the main pane shows.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Phase {
    Idle,
    Searching,
    Conversation,
}

impl AskPage {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        bind_keys(cx);
        let data = AppData::global(cx);
        let history_input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                "Search questions",
                window,
                cx,
            ))
        });
        let composer = cx.new(|cx| {
            TextareaState::new(window, cx)
                .auto_grow(1, 4)
                .submit_on_enter(true)
                .placeholder(crate::i18n::placeholder("Ask your work memory", window, cx))
        });
        let date_picker = cx.new(|cx| CalendarState::new(window, cx));
        let subscriptions = vec![
            cx.observe_in(&data, window, Self::on_data_changed),
            cx.subscribe_in(
                &date_picker,
                window,
                |this, _, event: &CalendarEvent, _, cx| {
                    let CalendarEvent::Selected(Date::Single(day)) = event else {
                        return;
                    };
                    this.picked_day = *day;
                    cx.notify();
                },
            ),
            cx.subscribe_in(
                &history_input,
                window,
                |this, input, event: &InputEvent, _, cx| {
                    if matches!(event, InputEvent::Change) {
                        this.history_query = input.read(cx).value().to_string();
                        cx.notify();
                    }
                },
            ),
            cx.subscribe_in(
                &composer,
                window,
                |this, input, event: &InputEvent, window, cx| match event {
                    InputEvent::Change => {
                        let value = input.read(cx).value().to_string();
                        if value != this.query {
                            this.query = value;
                            this.on_query_changed(window, cx);
                        }
                    }
                    InputEvent::PressEnter { secondary, shift } if !shift => {
                        this.submit(*secondary, window, cx)
                    }
                    _ => {}
                },
            ),
        ];
        let section = data.read(cx).section;
        let mut page = Self {
            data,
            conversations: Vec::new(),
            conversations_loaded: false,
            loaded_revision: None,
            selected: None,
            history_input,
            history_query: String::new(),
            composer,
            query: String::new(),
            sources: Sources::default(),
            date_scope: DateScope::AnyTime,
            facet: Facet::All,
            meeting_scope: None,
            pending_question: None,
            sources_expanded: false,
            date_picker,
            picked_day: None,
            results: Results::default(),
            search_task: None,
            turns: TurnState::default(),
            screen_citations: Default::default(),
            loading_screen_citations: HashSet::new(),
            transcript_scroll: ScrollHandle::new(),
            results_scroll: ScrollHandle::new(),
            history_scroll: ScrollHandle::new(),
            follow_stream: true,
            last_section: section,
            last_stream_len: 0,
            _subscriptions: subscriptions,
        };
        page.reload_conversations(cx);
        if section == Section::Ask {
            page.take_request(window, cx);
            page.focus_composer(window, cx);
        }
        page
    }

    fn on_data_changed(
        &mut self,
        data: Entity<AppData>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let (revision, section, stream_len, stream_here) = {
            let data = data.read(cx);
            let stream = data.ask_stream.as_ref();
            (
                data.revision,
                data.section,
                stream.map(|s| s.text.len() + s.activity.len()).unwrap_or(0),
                stream.is_some_and(|s| Some(s.conversation_id) == self.selected),
            )
        };
        if self.loaded_revision != Some(revision) {
            self.reload_conversations(cx);
        }
        if section == Section::Ask {
            self.take_request(window, cx);
            if self.last_section != Section::Ask {
                self.focus_composer(window, cx);
            }
        }
        self.last_section = section;
        if stream_here && stream_len != self.last_stream_len && self.follow_stream {
            self.transcript_scroll.scroll_to_bottom();
        }
        self.last_stream_len = stream_len;
        cx.notify();
    }

    // ------------------------------------------------------------ library

    fn reload_conversations(&mut self, cx: &mut Context<Self>) {
        let library = self.data.read(cx).library.clone();
        self.loaded_revision = Some(self.data.read(cx).revision);
        cx.spawn(async move |this, cx| {
            let loaded = cx
                .background_spawn(async move { library.conversations() })
                .await;
            let _ = this.update(cx, |this, cx| {
                match loaded {
                    Ok(conversations) => this.conversations = conversations,
                    Err(err) => log::warn!("reading Ask conversations failed: {err:#}"),
                }
                this.conversations_loaded = true;
                cx.notify();
            });
        })
        .detach();
    }

    fn conversation(&self, id: Uuid) -> Option<&Conversation> {
        self.conversations.iter().find(|c| c.id == id)
    }

    fn selected_conversation(&self) -> Option<&Conversation> {
        self.selected.and_then(|id| self.conversation(id))
    }

    fn delete_conversation(&mut self, id: Uuid, cx: &mut Context<Self>) {
        let library = self.data.read(cx).library.clone();
        self.conversations.retain(|c| c.id != id);
        if self.selected == Some(id) {
            self.selected = None;
        }
        cx.notify();
        let data = self.data.clone();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_spawn(async move { library.delete_conversation(id) })
                .await;
            if let Err(err) = result {
                data.update(cx, |data, cx| {
                    data.show_error(
                        lokalbot_i18n::format(
                            "Could not delete the question: {err}",
                            &[("err", format!("{:#}", err))],
                        ),
                        cx,
                    )
                });
                let _ = this.update(cx, |this, cx| this.reload_conversations(cx));
            }
        })
        .detach();
    }

    // ---------------------------------------------------------- navigation

    /// Consumes a question handed over by another page (`navigationHandoff`).
    fn take_request(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(request) = self.data.update(cx, |data, _| data.ask_request.take()) else {
            return;
        };
        let AskRequest {
            question,
            meeting_ids,
            submit,
        } = request;
        self.selected = None;
        self.date_scope = DateScope::AnyTime;
        self.facet = Facet::All;
        self.pending_question = None;
        self.meeting_scope = (!meeting_ids.is_empty()).then_some(meeting_ids);
        self.set_composer_text(&question, window, cx);
        if submit {
            self.submit(true, window, cx);
        }
        self.focus_composer(window, cx);
    }

    fn new_conversation(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.selected = None;
        self.meeting_scope = None;
        self.date_scope = DateScope::AnyTime;
        self.sources = Sources::default();
        self.facet = Facet::All;
        self.pending_question = None;
        self.set_composer_text("", window, cx);
        self.focus_composer(window, cx);
        cx.notify();
    }

    fn select_conversation(&mut self, id: Uuid, window: &mut Window, cx: &mut Context<Self>) {
        self.selected = Some(id);
        self.pending_question = None;
        self.follow_stream = true;
        self.set_composer_text("", window, cx);
        self.focus_composer(window, cx);
        self.transcript_scroll.scroll_to_bottom();
        cx.notify();
    }

    fn open_meeting(&mut self, meeting_id: Uuid, at: Option<f64>, cx: &mut Context<Self>) {
        let tab = if at.is_some() {
            MeetingTab::Transcript
        } else {
            MeetingTab::Summary
        };
        self.data
            .update(cx, |data, cx| data.open_meeting(meeting_id, tab, at, cx));
    }

    // ------------------------------------------------------------ composer

    fn set_composer_text(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.query = text.to_string();
        self.composer.update(cx, |state, cx| {
            state.set_value(text.to_string(), window, cx)
        });
        self.on_query_changed(window, cx);
    }

    fn focus_composer(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.composer
            .update(cx, |state, cx| state.focus(window, cx));
    }

    fn phase(&self, cx: &App) -> Phase {
        if !self.query.trim().is_empty() {
            return Phase::Searching;
        }
        let has_messages = self
            .selected_conversation()
            .is_some_and(|c| !c.messages.is_empty());
        let streaming_here = self
            .data
            .read(cx)
            .ask_stream
            .as_ref()
            .is_some_and(|s| Some(s.conversation_id) == self.selected);
        if has_messages || streaming_here {
            Phase::Conversation
        } else {
            Phase::Idle
        }
    }

    fn is_responding(&self, cx: &App) -> bool {
        self.data
            .read(cx)
            .ask_stream
            .as_ref()
            .is_some_and(|s| s.error.is_none())
    }

    /// Return asks a question or opens the selected result; Ctrl+Return
    /// always asks (`AskReturnAction`).
    fn submit(&mut self, force_ask: bool, window: &mut Window, cx: &mut Context<Self>) {
        let question = self.query.trim().to_string();
        if question.is_empty() || self.is_responding(cx) {
            return;
        }
        if !force_ask {
            let asks = !self.results.picked_with_keyboard && search::is_question(&question);
            if !asks {
                if self.results.query == self.query && !self.results.running {
                    self.open_selected_result(cx);
                }
                return;
            }
        }
        if self.results.running || self.results.query != self.query {
            // Ask once this text's sources are known, like "Waiting for sources…".
            self.pending_question = Some(self.query.clone());
            return;
        }
        self.ask(question, window, cx);
    }

    fn ask(&mut self, question: String, window: &mut Window, cx: &mut Context<Self>) {
        self.pending_question = None;
        if !self.results.meetings.is_empty() {
            self.meeting_scope = Some(self.results.meetings.iter().map(|g| g.meeting.id).collect());
        }
        let conversation_id = *self.selected.get_or_insert_with(Uuid::new_v4);
        let scope = scope::ask_scope(self.sources, self.date_scope, self.meeting_scope.as_deref());
        self.follow_stream = true;
        self.data.update(cx, |data, cx| {
            data.request(
                AppEvent::AskQuestion {
                    conversation_id,
                    question,
                    scope,
                },
                cx,
            )
        });
        self.set_composer_text("", window, cx);
        self.transcript_scroll.scroll_to_bottom();
        cx.notify();
    }

    /// Asks a suggestion straight away (`sendSuggestion`).
    fn ask_suggestion(&mut self, suggestion: &str, window: &mut Window, cx: &mut Context<Self>) {
        if self.is_responding(cx) {
            return;
        }
        self.results = Results::default();
        self.ask(suggestion.to_string(), window, cx);
    }

    fn stop_answer(&mut self, cx: &mut Context<Self>) {
        self.data
            .update(cx, |data, cx| data.request(AppEvent::StopAnswer, cx));
    }

    /// Asks the question behind `assistant_id` again in the same conversation.
    fn retry(&mut self, assistant_id: Uuid, cx: &mut Context<Self>) {
        let Some(conversation) = self.selected_conversation() else {
            return;
        };
        let conversation_id = conversation.id;
        let Some(index) = conversation
            .messages
            .iter()
            .position(|m| m.id == assistant_id)
        else {
            return;
        };
        let Some(question) = conversation.messages[..index]
            .iter()
            .rev()
            .find(|m| m.role == ChatRole::User)
            .map(|m| m.text.clone())
        else {
            return;
        };
        self.results = Results::default();
        let scope = scope::ask_scope(self.sources, self.date_scope, self.meeting_scope.as_deref());
        self.follow_stream = true;
        self.data.update(cx, |data, cx| {
            data.request(
                AppEvent::AskQuestion {
                    conversation_id,
                    question,
                    scope,
                },
                cx,
            )
        });
        self.transcript_scroll.scroll_to_bottom();
    }

    fn copy_answer(&mut self, message_id: Uuid, text: String, cx: &mut Context<Self>) {
        cx.write_to_clipboard(gpui_kit::ClipboardItem::new_string(text));
        self.turns.copied = Some(message_id);
        cx.notify();
        cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(1500))
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.turns.copied == Some(message_id) {
                    this.turns.copied = None;
                    cx.notify();
                }
            });
        })
        .detach();
    }

    // -------------------------------------------------------------- search

    fn on_query_changed(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if self.pending_question.as_deref() != Some(self.query.as_str()) {
            self.pending_question = None;
        }
        self.results.selected = 0;
        self.results.picked_with_keyboard = false;
        self.run_search(window, cx);
        cx.notify();
    }

    fn run_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let text = self.query.trim().to_string();
        self.results.query = self.query.clone();
        self.results.meetings.clear();
        self.results.screens.clear();
        self.results.truncated = false;
        self.results.expanded.clear();
        if text.is_empty() || !(self.sources.meetings || self.sources.screen) {
            self.results.running = false;
            self.search_task = None;
            return;
        }
        self.results.running = true;
        let (library, meetings) = {
            let data = self.data.read(cx);
            (data.library.clone(), data.meetings.clone())
        };
        let bounds = self.date_scope.bounds();
        let query = search::Query {
            text,
            facet: self.facet,
            meetings: self.sources.meetings,
            screen: self.sources.screen,
            meeting_ids: self.meeting_scope.clone(),
            since: bounds.map(|(since, _)| since),
            until: bounds.map(|(_, until)| until),
            limit: 50,
        };
        let for_query = self.query.clone();
        self.search_task = Some(cx.spawn_in(window, async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(160))
                .await;
            let found = cx
                .background_spawn(async move { search::run(&library, &meetings, &query) })
                .await;
            let _ = this.update_in(cx, |this, window, cx| {
                if this.query != for_query {
                    return;
                }
                this.results.meetings = found.meetings;
                this.results.screens = found.screens;
                this.results.truncated = found.truncated;
                this.results.running = false;
                this.results.selected = this
                    .results
                    .selected
                    .min(this.results.count().saturating_sub(1));
                cx.notify();
                if this.pending_question.as_deref() == Some(for_query.as_str()) {
                    this.ask(for_query.trim().to_string(), window, cx);
                }
            });
        }));
    }

    fn open_selected_result(&mut self, cx: &mut Context<Self>) {
        let selected = self.results.selected;
        if let Some(group) = self.results.meetings.get(selected) {
            let at = group.hits[0].moment();
            let id = group.meeting.id;
            self.open_meeting(id, at, cx);
        } else if let Some(screen) = self
            .results
            .screens
            .get(selected - self.results.meetings.len())
        {
            let moment = screen.moment.clone();
            open_screen_moment(&self.data, &moment, cx);
        }
    }

    fn move_selection(&mut self, delta: isize, cx: &mut Context<Self>) {
        let count = self.results.count();
        if count == 0 {
            return;
        }
        let next = (self.results.selected as isize + delta).clamp(0, count as isize - 1) as usize;
        self.results.selected = next;
        self.results.picked_with_keyboard = true;
        self.pending_question = None;
        self.results_scroll
            .scroll_to_item(next + results::HEADER_ROWS);
        cx.notify();
    }

    fn clear_filters(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.facet = Facet::All;
        self.date_scope = DateScope::AnyTime;
        self.run_search(window, cx);
        cx.notify();
    }

    /// Re-runs the search after a source, date or facet change.
    fn scope_changed(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.results.selected = 0;
        self.run_search(window, cx);
        cx.notify();
    }
}

impl Page for AskPage {
    fn title(&self, _cx: &App) -> SharedString {
        lokalbot_i18n::tr("Ask").into()
    }
}

impl Render for AskPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let phase = self.phase(cx);
        let body = match phase {
            Phase::Idle => self.render_empty_state(cx).into_any_element(),
            Phase::Searching => self.render_results(cx).into_any_element(),
            Phase::Conversation => self.render_transcript(window, cx).into_any_element(),
        };
        let searching = phase == Phase::Searching && self.results.count() > 0;
        h_flex()
            .size_full()
            .key_context(KEY_CONTEXT)
            .on_action(cx.listener(|this, _: &NewConversation, window, cx| {
                this.new_conversation(window, cx)
            }))
            .on_action(
                cx.listener(|this, _: &gpui_kit::component::input::Escape, _, cx| {
                    // Escape stops an answer in progress, like the macOS cancel action.
                    if this.is_responding(cx) {
                        this.stop_answer(cx);
                    } else {
                        cx.propagate();
                    }
                }),
            )
            .when(searching, |this| {
                this.capture_action(cx.listener(
                    |this, _: &gpui_kit::component::input::MoveUp, _, cx| {
                        this.move_selection(-1, cx);
                        cx.stop_propagation();
                    },
                ))
                .capture_action(cx.listener(
                    |this, _: &gpui_kit::component::input::MoveDown, _, cx| {
                        this.move_selection(1, cx);
                        cx.stop_propagation();
                    },
                ))
            })
            .bg(cx.lb().window)
            .child(self.render_history(window, cx))
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .child(div().flex_1().min_h_0().child(body))
                    .child(self.render_dock(window, cx)),
            )
    }
}
