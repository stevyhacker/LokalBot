//! Ask (`AskView.swift`, `ChatView.swift`): saved conversations in a
//! resizable column; beside it one field, one flow. Typing lists what matches
//! (under the field on a new question, in a tray above it inside a
//! conversation, which stays put); Return asks, ↓ then Return opens a match.
//! A full question reads everything in the chosen sources and dates; a word
//! or short phrase is answered from its matches (`AskAnswerScope`).

mod composer;
mod history;
mod matches;
pub(crate) mod model;
mod passage;
mod remember;

pub use composer::inference as composer_inference;
pub(crate) use history::row_timestamp;
pub(crate) use transcript::stop_answer_speech;
pub mod scope;
pub mod search;
mod transcript;

use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::time::Duration;

use crate::i18n::h_flex;
use chrono::{DateTime, Utc};
use gpui_kit::component::calendar::{CalendarEvent, CalendarState, Date};
use gpui_kit::component::input::{InputEvent, InputState, TextareaState};
use gpui_kit::component::v_flex;
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    App, AppContext as _, Context, Entity, InteractiveElement as _, IntoElement, KeyBinding,
    ParentElement as _, Render, ScrollHandle, SharedString, StatefulInteractiveElement as _,
    Styled as _, Subscription, Task, Window, actions, div,
};
use lokalbot_core::{Conversation, QuestionScope};
use uuid::Uuid;

use self::model::{AnswerScope, AskPhase, MatchCursor, PageKind, ReturnAction};
use self::scope::{DateScope, Evidence, Source, Sources};
use self::search::Facet;
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

/// What the field's text matches (`AskMatches`). A word's answer is limited
/// to these; a full question reads the chosen sources.
#[derive(Default)]
struct Results {
    /// The query these results belong to.
    query: String,
    running: bool,
    found: search::Results,
    /// In the field, Return asks; on a match, it opens it.
    cursor: MatchCursor,
    /// Rows whose folded lines are showing.
    expanded: HashSet<String>,
}

impl Results {
    /// Meeting groups, screen moments, files and agent notes, in list order.
    fn count(&self) -> usize {
        self.found.meetings.len()
            + self.found.screens.len()
            + self.found.files.len()
            + self.found.notes.len()
    }
}

/// A colleague and a project an empty page can name.
pub(super) struct SuggestionNames {
    person: Option<String>,
    project: Option<String>,
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

/// Per-message state in the conversation.
#[derive(Default)]
struct TurnState {
    /// Long questions shown in full.
    questions: HashSet<Uuid>,
    copied: Option<Uuid>,
    answers: HashMap<Uuid, (u64, Rc<Answer>)>,
}

pub struct AskPage {
    data: Entity<AppData>,
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
    /// Escape folded the tray above a docked field to its heading.
    tray_collapsed: bool,
    /// The time menu shows its date picker.
    choosing_date: bool,
    /// The passage behind a clicked citation number.
    passage: Option<passage::OpenPassage>,
    /// The passage a press outside it just closed, so a press on its own
    /// number closes it rather than opening it again.
    passage_dismissed: Option<(std::time::Instant, (Uuid, usize))>,
    /// Matches for a failed last answer, by answer; `None` while they load.
    failed_matches: HashMap<Uuid, Option<search::Results>>,
    suggestion_names: Option<SuggestionNames>,
    suggestion_names_revision: Option<u64>,
    /// When the unsaved new question was started, for its row in the list.
    draft_started: DateTime<Utc>,
    /// The page and language the field's placeholder was written for.
    placeholder: Option<(PageKind, &'static str)>,
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

impl AskPage {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let mut page = Self::build(window, cx);
        if page.last_section == Section::Ask {
            page.take_request(window, cx);
            page.focus_composer(window, cx);
        }
        page
    }

    fn build(window: &mut Window, cx: &mut Context<Self>) -> Self {
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
                .placeholder(crate::i18n::placeholder(
                    "Ask a question, or type a word to find it",
                    window,
                    cx,
                ))
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
                    InputEvent::PressEnter { shift, .. } if !shift => this.submit(window, cx),
                    _ => {}
                },
            ),
        ];
        let section = data.read(cx).section;
        let mut page = Self {
            data,
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
            tray_collapsed: false,
            choosing_date: false,
            passage: None,
            passage_dismissed: None,
            failed_matches: HashMap::new(),
            suggestion_names: None,
            suggestion_names_revision: None,
            draft_started: Utc::now(),
            placeholder: None,
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
        self.close_passage(cx);
        if self.selected.is_some() {
            self.draft_started = Utc::now();
        }
        self.selected = None;
        self.date_scope = day.map_or(DateScope::AnyTime, DateScope::Day);
        self.facet = Facet::All;
        self.pending_question = None;
        self.meeting_scope = (!meeting_ids.is_empty()).then_some(meeting_ids);
        self.screen_scope = None;
        self.restore_sources();
        // Quick Recall's "Show all" for one kind searches only that source.
        if let Some(sources) = self.data.update(cx, |data, _| data.ask_sources.take()) {
            self.sources = Sources::from_saved(&sources);
        }
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
        // A handed-over question is sent as it is, within what was handed over.
        if submit && !question.trim().is_empty() && !self.is_responding(cx) {
            self.ask(question.trim().to_string(), false, window, cx);
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
        self.close_passage(cx);
        if self.selected.is_some() {
            self.draft_started = Utc::now();
        }
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
        self.close_passage(cx);
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
    }

    // ------------------------------------------------------------ composer

    fn set_composer_text(&mut self, text: &str, window: &mut Window, cx: &mut Context<Self>) {
        self.query = text.to_string();
        self.composer.update(cx, |state, cx| {
            state.set_value(text.to_string(), window, cx);
            // A multi-line field puts its caret at the start; a question
            // handed over from elsewhere goes on from its end, as on the Mac.
            let end = state.text().len();
            state.set_selected_range(end..end, cx);
        });
        self.on_query_changed(window, cx);
    }

    fn focus_composer(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.composer
            .update(cx, |state, cx| state.focus(window, cx));
    }

    /// `AskRouter.phase`: a conversation once the selected one has turns (or
    /// one is being written), and typing whenever the field holds text.
    fn ask_phase(&self, cx: &App) -> AskPhase {
        let has_messages = self
            .selected_conversation()
            .is_some_and(|c| !c.messages.is_empty());
        let streaming_here = self
            .data
            .read(cx)
            .ask_stream
            .as_ref()
            .is_some_and(|s| Some(s.conversation_id) == self.selected);
        AskPhase::new(&self.query, has_messages || streaming_here)
    }

    fn is_responding(&self, cx: &App) -> bool {
        self.data
            .read(cx)
            .ask_stream
            .as_ref()
            .is_some_and(|s| s.error.is_none())
    }

    /// Return asks. After the arrow keys moved onto a match it opens that match
    /// instead (`AskReturnAction`).
    fn submit(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        match model::return_action(
            &self.query,
            self.results.count(),
            self.results.cursor.is_in_matches(),
        ) {
            ReturnAction::Ask => self.ask_about_results(window, cx),
            ReturnAction::OpenResult => {
                if self.results.query == self.query && !self.results.running {
                    self.open_selected_result(cx);
                }
            }
            ReturnAction::Nothing => {}
        }
    }

    /// `askAboutResults`: the button and Return. A question typed before its
    /// matches are in waits for them, so it never reads rows of earlier text.
    fn ask_about_results(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let question = self.query.trim().to_string();
        if question.is_empty() || self.is_responding(cx) {
            return;
        }
        if self.results.running || self.results.query != self.query {
            self.pending_question = Some(self.query.clone());
            cx.notify();
            return;
        }
        self.ask(question, true, window, cx);
    }

    /// Sends `question`. `from_field` applies `AskAnswerScope`: asked from the
    /// field, a word or short phrase is limited to its listed matches; a
    /// suggestion or a handed-over question is sent as it is.
    fn ask(
        &mut self,
        question: String,
        from_field: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.pending_question = None;
        // A full question reads everything in the chosen sources and dates, so
        // the sources menu keeps saying what was chosen. A word or short
        // phrase is a search being asked about: its answer is limited to the
        // listed matches, and the menu then names that limit. A "Remember …"
        // statement is saved as is. Scope set on purpose before this (a meeting
        // handed over, an attached screen, the menu's "Only …" state) stays.
        let remembers = self.data.read(cx).settings.ask_memory_enabled
            && lokalbot_core::personal::remember_statement(&question).is_some();
        let listed = self.results.query.trim() == question && self.results.count() > 0;
        if from_field
            && self.pins.is_empty()
            && AnswerScope::resolve(&question, listed, remembers) == AnswerScope::ListedMatches
        {
            // Bounds meetings and screen moments to the rows.
            let found = &self.results.found;
            self.meeting_scope = Some(found.meetings.iter().map(|g| g.meeting.id).collect());
            self.screen_scope = Some(found.screens.iter().map(|s| s.moment.id).collect());
            self.scope_from_results = true;
            self.scope_had_files = !found.files.is_empty();
            self.scope_had_notes = !found.notes.is_empty();
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
        self.tray_collapsed = false;
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
        self.ask(suggestion.to_string(), false, window, cx);
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

    /// `ChatViewModel.askAgain`: a finished answer's question, asked again as
    /// a new turn within the sources, dates and evidence it was asked in.
    fn ask_again(&mut self, assistant_id: Uuid, cx: &mut Context<Self>) {
        if self.is_responding(cx) {
            return;
        }
        let Some(conversation) = self.selected_conversation() else {
            return;
        };
        let conversation_id = conversation.id;
        let Some((question, saved)) = model::ask_again(&conversation.messages, assistant_id) else {
            return;
        };
        let scope = scope::scope_for(&saved);
        self.follow_stream = true;
        self.data.update(cx, |data, cx| {
            data.ask_question(conversation_id, question, scope, None, cx)
        });
        self.transcript_scroll.scroll_to_bottom();
        cx.notify();
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
        // Return can arrive before this; only a request for this exact text stays.
        if self.pending_question.as_deref() != Some(self.query.as_str()) {
            self.pending_question = None;
        }
        self.results.cursor.return_to_field();
        if self.query.trim().is_empty() {
            self.tray_collapsed = false;
        }
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
        // Never leave rows from a previous query available to Return.
        self.results.found = search::Results::default();
        self.results.cursor.return_to_field();
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
                this.results.found = found.clone();
                this.results.running = false;
                let count = this.results.count();
                this.results.cursor.clamp(count);
                cx.notify();
                if this.pending_question.as_deref() == Some(for_query.as_str()) {
                    this.ask(for_query.trim().to_string(), true, window, cx);
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
                this.results.found = refined;
                let count = this.results.count();
                this.results.cursor.clamp(count);
                cx.notify();
            });
        }));
    }

    fn open_selected_result(&mut self, cx: &mut Context<Self>) {
        let Some(selected) = self.results.cursor.index() else {
            return;
        };
        let found = &self.results.found;
        let (meetings, screens, files) =
            (found.meetings.len(), found.screens.len(), found.files.len());
        if let Some(group) = found.meetings.get(selected) {
            let at = group.hits.first().and_then(search::Hit::moment);
            let id = group.meeting.id;
            self.open_meeting(id, at, cx);
        } else if let Some(screen) = found.screens.get(selected - meetings) {
            let moment = screen.moment.clone();
            open_screen_moment(&self.data, &moment, cx);
        } else if let Some(hit) = found.files.get(selected - meetings - screens) {
            search::open_file(hit);
        } else if let Some(hit) = found.notes.get(selected - meetings - screens - files) {
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

    /// The arrow keys move between the field and the matches. `false` when
    /// the key is the field's (Up in the field, or nothing listed).
    fn move_cursor(&mut self, down: bool, cx: &mut Context<Self>) -> bool {
        let phase = self.ask_phase(cx);
        let count = self.results.count();
        if !phase.typing || count == 0 || !self.results.cursor.step(down, count) {
            return false;
        }
        self.tray_collapsed = false;
        self.pending_question = None;
        if let Some(index) = self.results.cursor.index() {
            // Under the field the heading is the scrolling column's first child.
            let offset = usize::from(phase.page == PageKind::NewQuestion);
            self.results_scroll.scroll_to_item(index + offset);
        }
        cx.notify();
        true
    }

    /// Escape first returns the keyboard to the field, then stops an answer
    /// being written, then folds the tray. `false` when it isn't Ask's.
    fn escape(&mut self, cx: &mut Context<Self>) -> bool {
        if self.passage.is_some() {
            self.close_passage(cx);
            return true;
        }
        if self.results.cursor.is_in_matches() {
            self.results.cursor.return_to_field();
            cx.notify();
            return true;
        }
        if self.is_responding(cx) {
            self.stop_answer(cx);
            return true;
        }
        let tray =
            self.ask_phase(cx).matches_placement() == Some(model::MatchesPlacement::TrayAboveField);
        if tray && self.results.count() > 0 && !self.tray_collapsed {
            self.tray_collapsed = true;
            cx.notify();
            return true;
        }
        false
    }

    fn clear_filters(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.facet = Facet::All;
        self.screen_app = None;
        self.date_scope = DateScope::AnyTime;
        self.run_search(window, cx);
        cx.notify();
    }

    /// Lifts the limit to particular meetings and screen moments, back to the
    /// sources chosen before it (`widenSources`).
    fn widen_sources(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.pins.clear();
        self.meeting_scope = None;
        self.screen_scope = None;
        self.restore_sources();
        self.scope_from_results = false;
        self.scope_had_files = false;
        self.scope_had_notes = false;
        self.scope_changed(window, cx);
    }

    /// An explicit source choice supersedes an earlier temporary narrowing's
    /// way back (`chooseSources`).
    fn toggle_source(&mut self, source: Source, window: &mut Window, cx: &mut Context<Self>) {
        let offered = self.offered(cx);
        self.sources.toggle(source, offered);
        self.sources_before_evidence = None;
        if !self.sources.screen {
            self.screen_app = None;
        }
        self.scope_changed(window, cx);
    }

    /// What the sources menu's button says, and its "Only …" rows.
    fn scope_summary(&self, cx: &App) -> model::ScopeSummary {
        let offered = self.offered(cx);
        let bound = scope::ask_scope(self.sources, self.date_scope, &self.evidence());
        let effective = Sources {
            meetings: bound.include_meetings,
            activity: bound.include_activity,
            screen: bound.include_screen,
            files: bound.include_files,
            agent_notes: bound.include_agent_notes,
        };
        // Attached screens limit the screen source to themselves.
        let pins: Vec<i64> = self.pins.iter().map(|pin| pin.id).collect();
        let screen_ids = self
            .screen_scope
            .as_deref()
            .or((!pins.is_empty()).then_some(pins.as_slice()));
        let meetings = &self.data.read(cx).meetings;
        model::scope_summary(
            &model::ScopeInput {
                sources: self.sources,
                effective,
                offered,
                meeting_ids: self.meeting_scope.as_deref(),
                screen_ids,
                widen_to: self.sources_before_evidence.unwrap_or(self.sources),
                facet: self.facet,
                screen_app: self.screen_app.as_deref(),
            },
            |id| {
                meetings
                    .iter()
                    .find(|m| m.id == id)
                    .map(|m| m.display_title())
            },
        )
    }

    /// Re-runs the search after a source, date or facet change.
    fn scope_changed(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if let Some((since, until)) = self.date_scope.bounds() {
            self.pins.retain(|pin| pin.ts >= since && pin.ts < until);
        }
        self.run_search(window, cx);
        cx.notify();
    }

    /// The field's placeholder names what it does on this page.
    fn sync_placeholder(&mut self, page: PageKind, window: &mut Window, cx: &mut Context<Self>) {
        let language = lokalbot_i18n::current().code;
        if self.placeholder == Some((page, language)) {
            return;
        }
        self.placeholder = Some((page, language));
        let key = match page {
            PageKind::NewQuestion => "Ask a question, or type a word to find it",
            PageKind::Conversation => "Ask a follow-up",
        };
        self.composer.update(cx, |state, cx| {
            state.set_placeholder(lokalbot_i18n::tr(key).to_string(), window, cx)
        });
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
        let lb = cx.lb().clone();
        let phase = self.ask_phase(cx);
        self.sync_placeholder(phase.page, window, cx);
        let problem = self.conversations_problem.clone().map(|problem| {
            div()
                .px(gpui_kit::px(16.))
                .py(gpui_kit::px(8.))
                .text_size(crate::theme::ty::SECONDARY)
                .text_color(lb.attention_text)
                .child(crate::ui::text::paragraph(problem))
        });
        let field = self.render_field_column(phase.page, window, cx);
        let detail = match phase.page {
            PageKind::NewQuestion => {
                // The field sits a sixth of the way down, never past 150 pt.
                let height = window.viewport_size().height - crate::theme::metric::TOOLBAR_HEIGHT;
                let top = (height * 0.17).clamp(gpui_kit::px(28.), gpui_kit::px(150.));
                let below = if phase.shows_suggestions() {
                    self.render_suggestions(cx)
                } else {
                    self.render_matches_under_field(cx)
                };
                v_flex()
                    .size_full()
                    .min_w_0()
                    .children(problem)
                    .child(
                        v_flex().w_full().items_center().child(
                            div()
                                .w_full()
                                .max_w(crate::theme::metric::READING_MAX_WIDTH)
                                .px(crate::theme::metric::DETAIL_PADDING)
                                .pt(top)
                                .pb(gpui_kit::px(18.))
                                .text_center()
                                .text_size(gpui_kit::px(22.))
                                .line_height(gpui_kit::px(28.))
                                .font_weight(gpui_kit::FontWeight::BOLD)
                                .text_color(lb.text)
                                .child(lokalbot_i18n::tr(
                                    "Ask about your meetings, screen and files",
                                )),
                        ),
                    )
                    .child(field)
                    .child(
                        v_flex()
                            .id("ask-below-field")
                            .flex_1()
                            .min_h_0()
                            .w_full()
                            .items_center()
                            .overflow_y_scroll()
                            .track_scroll(&self.results_scroll)
                            .children(below.into_iter().map(|child| {
                                div()
                                    .w_full()
                                    .max_w(crate::theme::metric::READING_MAX_WIDTH)
                                    .px(crate::theme::metric::DETAIL_PADDING)
                                    .child(child)
                            }))
                            .child(div().h(crate::theme::metric::DETAIL_PADDING)),
                    )
                    .into_any_element()
            }
            PageKind::Conversation => {
                let tray = self.render_matches_tray(cx);
                v_flex()
                    .size_full()
                    .min_w_0()
                    .children(problem)
                    .child(
                        div()
                            .relative()
                            .flex_1()
                            .min_h_0()
                            .child(self.render_transcript(window, cx))
                            .when_some(tray, |this, tray| {
                                this.child(
                                    h_flex()
                                        .absolute()
                                        .bottom(gpui_kit::px(2.))
                                        .left_0()
                                        .right_0()
                                        .justify_center()
                                        .child(
                                            div()
                                                .w_full()
                                                .max_w(crate::theme::metric::READING_MAX_WIDTH)
                                                .px(crate::theme::metric::DETAIL_PADDING)
                                                .child(tray),
                                        ),
                                )
                            }),
                    )
                    .child(field)
                    .into_any_element()
            }
        };
        let typing_with_matches = phase.typing && self.results.count() > 0;
        h_flex()
            .size_full()
            .key_context(KEY_CONTEXT)
            .on_action(cx.listener(|this, _: &NewConversation, window, cx| {
                this.new_conversation(window, cx)
            }))
            .on_action(
                cx.listener(|this, _: &gpui_kit::component::input::Escape, _, cx| {
                    if !this.escape(cx) {
                        cx.propagate();
                    }
                }),
            )
            .when(typing_with_matches, |this| {
                this.capture_action(cx.listener(
                    |this, _: &gpui_kit::component::input::MoveUp, _, cx| {
                        if this.move_cursor(false, cx) {
                            cx.stop_propagation();
                        }
                    },
                ))
                .capture_action(cx.listener(
                    |this, _: &gpui_kit::component::input::MoveDown, _, cx| {
                        if this.move_cursor(true, cx) {
                            cx.stop_propagation();
                        }
                    },
                ))
            })
            .bg(lb.page)
            .child(crate::ui::split::leading(
                "LokalBot.ask",
                crate::theme::metric::CONTENT_COLUMN_WIDTH,
                crate::ui::split::LIST_RANGE,
                self.render_history(window, cx),
                detail,
                &self.data,
                cx,
            ))
    }
}
