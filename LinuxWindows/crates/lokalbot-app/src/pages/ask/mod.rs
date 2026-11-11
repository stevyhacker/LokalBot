//! Ask (`AskView.swift`, `ChatView.swift`): saved conversations on the left;
//! on the right an empty state, keyword results while typing, or the
//! conversation, with the composer docked at the bottom.

mod composer;
mod history;
mod remember;

pub use composer::inference as composer_inference;
pub(crate) use history::row_timestamp;
pub(crate) use transcript::stop_answer_speech;
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
use lokalbot_core::{Conversation, QuestionScope};
use uuid::Uuid;

use self::scope::{DateScope, Evidence, Sources};
use self::search::{Facet, MeetingGroup, ScreenResult};
use crate::pages::Page;
use crate::state::{AppData, AppEvent, AskRequest, MeetingTab, Section};
use crate::theme::LbThemeExt as _;
use crate::ui::answer_text::Answer;
use crate::ui::screen_thumbnail::ScreenThumbnails;

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
    files: Vec<lokalbot_core::files::FileHit>,
    notes: Vec<lokalbot_core::agent_notes::NoteHit>,
    truncated: bool,
    selected: usize,
    /// Arrow keys picked a row, so Return opens it even for a question.
    picked_with_keyboard: bool,
    expanded: HashSet<Uuid>,
}

impl Results {
    /// Meeting groups, screen moments, files and agent notes, in list order.
    fn count(&self) -> usize {
        self.meetings.len() + self.screens.len() + self.files.len() + self.notes.len()
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
    /// Only the conversation, inside Quick Recall: it leaves navigation requests
    /// and the keyboard to the Ask page.
    embedded: bool,
    conversations: Vec<Conversation>,
    conversations_loaded: bool,
    /// How many reloads have started, and the latest one taken: a read that
    /// started earlier and finished later is out of date, and so is every
    /// read that started before a conversation was deleted here.
    reloads_started: u64,
    reload_applied: u64,
    /// Why saved conversations couldn't all be opened or saved.
    conversations_problem: Option<String>,
    remember: remember::RememberState,
    loaded_revision: Option<u64>,
    /// The conversation on screen; `None` is a new, empty conversation.
    selected: Option<Uuid>,
    /// Selected before it was loaded: its scope is restored once it is.
    pending_restore: Option<Uuid>,
    history_input: Entity<InputState>,
    history_query: String,
    composer: Entity<TextareaState>,
    query: String,
    sources: Sources,
    date_scope: DateScope,
    facet: Facet,
    /// Evidence boundary from "Ask This Meeting" or from asking about results.
    meeting_scope: Option<Vec<Uuid>>,
    /// The screen moments among the results a question was asked about, or a work
    /// session's moments from Timeline.
    screen_scope: Option<Vec<i64>>,
    /// The sources to go back to when a session's boundary is cleared.
    sources_before_evidence: Option<Sources>,
    /// Asked about results: a selected Activity source stays, and Files with file rows.
    scope_from_results: bool,
    scope_had_files: bool,
    /// Asking about results kept Agent notes: note rows were among them.
    scope_had_notes: bool,
    /// Screens attached to the next question as primary evidence.
    pins: Vec<lokalbot_core::ScreenMoment>,
    thumbnails: ScreenThumbnails,
    /// Limit screen results and the assistant's screen search to one app.
    screen_app: Option<String>,
    /// The apps in the last results, for the filter.
    screen_apps: Vec<String>,
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
    loading_file_citations: HashSet<i64>,
    loading_note_citations: HashSet<String>,
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
        let mut page = Self::build(false, window, cx);
        if page.last_section == Section::Ask {
            page.take_request(window, cx);
            page.focus_composer(window, cx);
        }
        page
    }

    /// One conversation's transcript, for Quick Recall to show.
    pub fn embedded(conversation: Uuid, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let mut page = Self::build(true, window, cx);
        page.selected = Some(conversation);
        page
    }

    fn build(embedded: bool, window: &mut Window, cx: &mut Context<Self>) -> Self {
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
            embedded,
            conversations: Vec::new(),
            conversations_loaded: false,
            reloads_started: 0,
            reload_applied: 0,
            conversations_problem: None,
            remember: Default::default(),
            loaded_revision: None,
            selected: None,
            pending_restore: None,
            history_input,
            history_query: String::new(),
            composer,
            query: String::new(),
            sources: Sources::default(),
            date_scope: DateScope::AnyTime,
            facet: Facet::All,
            meeting_scope: None,
            screen_scope: None,
            sources_before_evidence: None,
            scope_from_results: false,
            scope_had_files: false,
            scope_had_notes: false,
            pins: Vec::new(),
            thumbnails: ScreenThumbnails::default(),
            screen_app: None,
            screen_apps: Vec::new(),
            pending_question: None,
            sources_expanded: false,
            date_picker,
            picked_day: None,
            results: Results::default(),
            search_task: None,
            turns: TurnState::default(),
            screen_citations: Default::default(),
            loading_screen_citations: HashSet::new(),
            loading_file_citations: HashSet::new(),
            loading_note_citations: HashSet::new(),
            transcript_scroll: ScrollHandle::new(),
            results_scroll: ScrollHandle::new(),
            history_scroll: ScrollHandle::new(),
            follow_stream: true,
            last_section: section,
            last_stream_len: 0,
            _subscriptions: subscriptions,
        };
        page.reload_conversations(cx);
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
        if section == Section::Ask && !self.embedded {
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
        self.reloads_started += 1;
        let reload = self.reloads_started;
        cx.spawn(async move |this, cx| {
            let (loaded, claims) = cx
                .background_spawn(async move {
                    let loaded = library.load_conversations();
                    // Only conversations that used it wake the credential store.
                    let uses_claims = loaded.conversations.iter().any(|c| {
                        c.messages
                            .iter()
                            .any(|m| m.remember_receipt.is_some() || m.used_claim_ids.is_some())
                    });
                    let claims = if uses_claims {
                        library.personal().claims()
                    } else {
                        Vec::new()
                    };
                    (loaded, claims)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if reload <= this.reload_applied {
                    return;
                }
                this.reload_applied = reload;
                this.conversations_problem = loaded.problem();
                this.conversations = loaded.conversations;
                this.remember.claims = claims.into_iter().map(|c| (c.id, c)).collect();
                this.conversations_loaded = true;
                if let Some(id) = this.pending_restore
                    && this.conversation(id).is_some()
                {
                    this.pending_restore = None;
                    this.restore_question_scope(id);
                }
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

    /// What a follow-up in this conversation asks within: its latest question's
    /// scope. `None` until the conversation is known, rather than a wider guess.
    pub fn follow_up_scope(&self, id: Uuid) -> Option<crate::state::AskScope> {
        let saved = QuestionScope::current(&self.conversation(id)?.messages)?;
        Some(scope::scope_for(&saved))
    }

    fn delete_conversation(&mut self, id: Uuid, cx: &mut Context<Self>) {
        let library = self.data.read(cx).library.clone();
        self.data.update(cx, |data, cx| {
            data.attached_asks.remove(&id);
            // An answer still being written doesn't bring it back.
            if data
                .ask_stream
                .as_ref()
                .is_some_and(|s| s.conversation_id == id)
            {
                data.request(AppEvent::StopAnswer, cx);
            }
        });
        self.conversations.retain(|c| c.id != id);
        // A read already under way may still list it, so none of those is
        // taken; the read below, after the file is gone, replaces them.
        self.reload_applied = self.reloads_started;
        if self.selected == Some(id) {
            self.selected = None;
            self.reset_scope();
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
            }
            let _ = this.update(cx, |this, cx| this.reload_conversations(cx));
        })
        .detach();
    }

    // ---------------------------------------------------------- navigation

    /// Consumes a question handed over by another page (`navigationHandoff`).
    fn take_request(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(id) = self
            .data
            .update(cx, |data, _| data.ask_open_conversation.take())
        {
            self.select_conversation(id, window, cx);
        }
        let Some(request) = self.data.update(cx, |data, _| data.ask_request.take()) else {
            return;
        };
        let AskRequest {
            question,
            meeting_ids,
            submit,
            day,
        } = request;
        self.selected = None;
        self.date_scope = day.map_or(DateScope::AnyTime, DateScope::Day);
        self.facet = Facet::All;
        self.pending_question = None;
        self.meeting_scope = (!meeting_ids.is_empty()).then_some(meeting_ids);
        self.screen_scope = None;
        self.restore_sources();
        self.scope_from_results = false;
        self.scope_had_files = false;
        self.scope_had_notes = false;
        // A single moment is an attachment, not a retrieval boundary.
        self.pins.clear();
        if let Some(moment) = self.data.update(cx, |data, _| data.ask_screen.take()) {
            self.pins.push(moment);
        }
        // A session's moments are a boundary: never copied into the prompt.
        if let Some(ids) = self.data.update(cx, |data, _| data.ask_screens.take()) {
            self.sources_before_evidence = Some(self.sources);
            self.sources = scope::evidence_sources(self.meeting_scope.as_deref(), &ids);
            self.screen_scope = Some(ids);
        }
        self.set_composer_text(&question, window, cx);
        if submit {
            self.submit(true, window, cx);
        }
        self.focus_composer(window, cx);
    }

    /// `clearEvidence`: a session's boundary narrowed the sources; this undoes it.
    fn restore_sources(&mut self) {
        if let Some(sources) = self.sources_before_evidence.take() {
            self.sources = sources;
        }
    }

    /// `resetAskScope`: everything open again, for a new question.
    fn reset_scope(&mut self) {
        self.meeting_scope = None;
        self.screen_scope = None;
        self.sources_before_evidence = None;
        self.scope_from_results = false;
        self.scope_had_files = false;
        self.scope_had_notes = false;
        self.pins.clear();
        self.screen_app = None;
        self.date_scope = DateScope::AnyTime;
        self.sources = Sources::default();
    }

    /// `restoreAskScope`: the composer goes back to what the conversation's latest
    /// question asked within, so what's asked next can't reach further unnoticed.
    fn restore_question_scope(&mut self, id: Uuid) {
        let Some(saved) = self
            .conversation(id)
            .and_then(|conversation| QuestionScope::current(&conversation.messages))
        else {
            self.reset_scope();
            return;
        };
        let restored = scope::restore(&saved);
        self.pins.clear();
        if restored.evidence.meetings.is_some() || restored.evidence.screens.is_some() {
            self.sources_before_evidence.get_or_insert(self.sources);
        } else {
            self.restore_sources();
        }
        self.sources = restored.sources;
        self.date_scope = restored.date;
        self.meeting_scope = restored.evidence.meetings;
        self.screen_scope = restored.evidence.screens;
        self.scope_from_results = restored.evidence.from_results;
        self.scope_had_files = restored.evidence.had_file_results;
        self.scope_had_notes = restored.evidence.had_note_results;
        self.screen_app = restored.evidence.screen_app;
    }

    fn new_conversation(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        transcript::stop_answer_speech(cx);
        self.selected = None;
        self.pending_restore = None;
        self.reset_scope();
        self.facet = Facet::All;
        self.pending_question = None;
        self.set_composer_text("", window, cx);
        self.focus_composer(window, cx);
        cx.notify();
    }

    fn select_conversation(&mut self, id: Uuid, window: &mut Window, cx: &mut Context<Self>) {
        transcript::stop_answer_speech(cx);
        self.selected = Some(id);
        if self.conversation(id).is_some() {
            self.pending_restore = None;
            self.restore_question_scope(id);
        } else {
            self.pending_restore = Some(id);
        }
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
        self.reveal_main_window(cx);
    }

    /// Inside Quick Recall, what a citation opens is in the main window.
    fn reveal_main_window(&self, cx: &mut App) {
        if self.embedded {
            crate::windows::activate_main(cx);
        }
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

    /// Return asks a question, saves a "Remember …" or opens the selected result;
    /// Ctrl+Return always asks (`AskReturnAction`).
    fn submit(&mut self, force_ask: bool, window: &mut Window, cx: &mut Context<Self>) {
        let question = self.query.trim().to_string();
        if question.is_empty() || self.is_responding(cx) {
            return;
        }
        if !force_ask {
            let action = search::return_action(
                &question,
                self.results.count(),
                self.results.picked_with_keyboard,
            );
            match action {
                search::ReturnAction::Ask => {}
                search::ReturnAction::OpenResult | search::ReturnAction::Nothing => {
                    if action == search::ReturnAction::OpenResult
                        && self.results.query == self.query
                        && !self.results.running
                    {
                        self.open_selected_result(cx);
                    }
                    return;
                }
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
        // A "Remember …" statement is saved as is: Ask isn't narrowed to the
        // results its words happened to match.
        let remembers = self.data.read(cx).settings.ask_memory_enabled
            && lokalbot_core::personal::remember_statement(&question).is_some();
        if self.results.count() > 0 && self.pins.is_empty() && !remembers {
            // "Ask about results" bounds meetings and screen moments to the rows.
            self.meeting_scope = Some(self.results.meetings.iter().map(|g| g.meeting.id).collect());
            self.screen_scope = Some(self.results.screens.iter().map(|s| s.moment.id).collect());
            self.scope_from_results = true;
            self.scope_had_files = !self.results.files.is_empty();
            self.scope_had_notes = !self.results.notes.is_empty();
        }
        let conversation_id = *self.selected.get_or_insert_with(Uuid::new_v4);
        let scope = scope::ask_scope(self.sources, self.date_scope, &self.evidence());
        // What it attached stays the boundary for the questions after it; only
        // the captured text leaves (`clearPins(restoringScope: false)`).
        if !self.pins.is_empty() {
            self.screen_scope = Some(self.pins.iter().map(|pin| pin.id).collect());
            self.sources.screen = true;
            self.scope_from_results = true;
            self.scope_had_files = self.sources.files;
            self.scope_had_notes = self.sources.agent_notes;
            self.pins.clear();
        }
        self.follow_stream = true;
        self.data.update(cx, |data, cx| {
            data.ask_question(conversation_id, question, scope, None, cx)
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

    /// `ChatViewModel.retry`: asks the question behind a failed turn again, within
    /// the scope it was asked in, not whatever the composer holds now.
    fn retry(&mut self, assistant_id: Uuid, cx: &mut Context<Self>) {
        let Some(conversation) = self.selected_conversation() else {
            return;
        };
        let conversation_id = conversation.id;
        let live = self
            .data
            .read(cx)
            .attached_asks
            .get(&conversation_id)
            .cloned();
        if !lokalbot_core::can_retry(&conversation.messages, assistant_id, live.is_some()) {
            return;
        }
        let Some((question, saved)) =
            lokalbot_core::retry_question(&conversation.messages, assistant_id)
        else {
            return;
        };
        let scope = match live {
            Some(live) if !saved.attached_screen_day_keys.is_empty() => live,
            _ => scope::scope_for(&saved),
        };
        self.results = Results::default();
        self.follow_stream = true;
        self.data.update(cx, |data, cx| {
            data.ask_question(conversation_id, question, scope, Some(assistant_id), cx)
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

    fn evidence(&self) -> Evidence {
        Evidence {
            meetings: self.meeting_scope.clone(),
            screens: self.screen_scope.clone(),
            from_results: self.scope_from_results,
            had_file_results: self.scope_had_files,
            had_note_results: self.scope_had_notes,
            pins: self.pins.iter().map(|moment| moment.id).collect(),
            pin_days: scope::pin_days(&self.pins),
            screen_app: self.screen_app.clone(),
        }
    }

    /// The optional sources that are on, so they can be offered and searched.
    fn offered(&self, cx: &App) -> scope::Offered {
        scope::Offered::new(&self.data.read(cx).settings)
    }

    fn run_search(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let text = self.query.trim().to_string();
        self.results.query = self.query.clone();
        self.results.meetings.clear();
        self.results.screens.clear();
        self.results.files.clear();
        self.results.notes.clear();
        self.results.truncated = false;
        self.results.expanded.clear();
        let offered = self.offered(cx);
        let searches_files = self.sources.files && offered.files;
        let searches_notes = self.sources.agent_notes && offered.agent_notes;
        if text.is_empty()
            || !(self.sources.meetings || self.sources.screen || searches_files || searches_notes)
        {
            self.results.running = false;
            self.search_task = None;
            return;
        }
        self.results.running = true;
        let (library, meetings, file_folders) = {
            let data = self.data.read(cx);
            (
                data.library.clone(),
                data.meetings.clone(),
                if searches_files {
                    data.settings.file_search_folders.clone()
                } else {
                    Vec::new()
                },
            )
        };
        let bounds = self.date_scope.bounds();
        let query = search::Query {
            text,
            facet: self.facet,
            meetings: self.sources.meetings,
            screen: self.sources.screen,
            file_folders,
            agent_notes: searches_notes,
            screen_app: self.screen_app.clone(),
            screen_ids: self.screen_scope.clone(),
            meeting_ids: self.meeting_scope.clone(),
            since: bounds.map(|(since, _)| since),
            until: bounds.map(|(_, until)| until),
            limit: search::DISPLAY_LIMIT,
        };
        let for_query = self.query.clone();
        self.search_task = Some(cx.spawn_in(window, async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(160))
                .await;
            let (lexical_library, lexical_query, lexical_meetings) =
                (library.clone(), query.clone(), meetings.clone());
            let mut found = cx
                .background_spawn(async move {
                    search::run(&lexical_library, &lexical_meetings, &lexical_query)
                })
                .await;
            let _ = this.update_in(cx, |this, window, cx| {
                if this.query != for_query {
                    return;
                }
                this.screen_apps = search::screen_apps(&found.screens, this.screen_app.as_deref());
                this.results.meetings = found.meetings.clone();
                this.results.screens = found.screens.clone();
                this.results.files = found.files.clone();
                this.results.notes = found.notes.clone();
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
            if !query.wants_meaning() {
                return;
            }
            // Meaning second, so words show at once.
            let refined = cx
                .background_spawn(async move {
                    let vector = lokalbot_engine::query_vector(query.text.trim())?;
                    search::refine(&library, &query, &vector, &mut found);
                    search::fuse_meetings(&library, &meetings, &query, &vector, &mut found);
                    Some(found)
                })
                .await;
            let Some(refined) = refined else {
                return;
            };
            let _ = this.update(cx, |this, cx| {
                if this.query != for_query {
                    return;
                }
                this.screen_apps =
                    search::screen_apps(&refined.screens, this.screen_app.as_deref());
                this.results.meetings = refined.meetings;
                this.results.screens = refined.screens;
                this.results.files = refined.files;
                this.results.notes = refined.notes;
                this.results.truncated = refined.truncated;
                this.results.selected = this
                    .results
                    .selected
                    .min(this.results.count().saturating_sub(1));
                cx.notify();
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
        } else if let Some(hit) = self
            .results
            .files
            .get(selected - self.results.meetings.len() - self.results.screens.len())
        {
            search::open_file(hit);
        } else if let Some(hit) = self.results.notes.get(
            selected
                - self.results.meetings.len()
                - self.results.screens.len()
                - self.results.files.len(),
        ) {
            search::open_note(hit);
        }
    }

    /// Attaches a screen moment to the next question, or takes it off. Attached
    /// moments outside the chosen dates are dropped as the dates change.
    fn toggle_pin(&mut self, moment: &lokalbot_core::ScreenMoment, cx: &mut Context<Self>) {
        if let Some(at) = self.pins.iter().position(|pin| pin.id == moment.id) {
            self.pins.remove(at);
        } else {
            self.pins.push(moment.clone());
        }
        cx.notify();
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
        self.screen_app = None;
        self.date_scope = DateScope::AnyTime;
        self.run_search(window, cx);
        cx.notify();
    }

    /// Re-runs the search after a source, date or facet change.
    fn scope_changed(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some((since, until)) = self.date_scope.bounds() {
            self.pins.retain(|pin| pin.ts >= since && pin.ts < until);
        }
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
        self.thumbnails.drop_released(window, cx);
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
            .child(crate::ui::split::leading(
                "LokalBot.ask",
                crate::theme::metric::CONTENT_COLUMN_WIDTH,
                crate::ui::split::LIST_RANGE,
                self.render_history(window, cx),
                v_flex()
                    .size_full()
                    .min_w_0()
                    .when_some(self.conversations_problem.clone(), |this, problem| {
                        this.child(
                            div()
                                .px(gpui_kit::px(16.))
                                .py(gpui_kit::px(8.))
                                .text_size(crate::theme::ty::SECONDARY)
                                .text_color(cx.lb().attention_text)
                                .child(crate::ui::text::paragraph(problem)),
                        )
                    })
                    .child(div().flex_1().min_h_0().child(body))
                    .child(self.render_dock(window, cx)),
                &self.data,
                cx,
            ))
    }
}
