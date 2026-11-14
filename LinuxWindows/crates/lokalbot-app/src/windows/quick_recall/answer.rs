//! The answer inside the Quick Recall window (`ChatTranscriptView` in its
//! compact style, `QuickRecallAnswerSources`): each question under "You" and
//! its time, the answer, and its sources as numbered rows laid out like the
//! window's results, with the passage quoted and the question's words marked.
//! Opening a source shows it in the main window, or in its own app for a file
//! or an agent note. It reads the conversation the engine saves and the
//! answer being written; it never asks anything itself.
//!
//! Built on its own rather than on the Ask page, so the window keeps working
//! while Ask changes; what it shares with Ask is the citation parser, the
//! answer renderer and the question scope.

use std::collections::hash_map::DefaultHasher;
use std::collections::{HashMap, HashSet};
use std::hash::{Hash as _, Hasher as _};
use std::rc::Rc;

use chrono::{DateTime, Local, Utc};
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Div, Entity, EventEmitter, FontWeight,
    InteractiveElement as _, IntoElement, ParentElement as _, Render, ScrollHandle, SharedString,
    StatefulInteractiveElement as _, Styled as _, Subscription, Window, div, px,
};
use lokalbot_core::{ChatRole, Conversation, QuestionScope, Segment, Transcript};
use uuid::Uuid;

use super::model;
use super::rows::{self, RowColors};
use crate::i18n::h_flex;
use crate::pages::ask::scope::{self, Offered};
use crate::pages::ask::search;
use crate::state::{AppData, AskScope, MeetingTab};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::answer_text::{self, Answer, AnswerStyle};
use crate::ui::citations::{self, CitationSource, ScreenCitations};
use crate::ui::{self, Ico};

/// Id of the answer being written before the engine saves it.
const STREAM_ID: Uuid = Uuid::from_u128(0x5a5a_0000_0000_4000_8000_0000_0000_0002);
/// Characters of a source's quoted line.
const QUOTE_LIMIT: usize = 200;

/// A source was opened from the answer: the window closes, bringing the main
/// window forward when that is where the source shows.
pub enum AnswerEvent {
    Opened { in_main_window: bool },
}

/// One turn as the window shows it.
enum Turn {
    Question {
        text: String,
        created_at: Option<DateTime<Utc>>,
        first: bool,
    },
    Answer {
        id: Uuid,
        text: String,
        /// The step under way, while the answer is being prepared.
        step: Option<String>,
        pending: bool,
        status: Option<SharedString>,
        error: Option<String>,
        receipt: bool,
        used_claims: usize,
        question: String,
    },
}

pub struct QuickRecallAnswer {
    data: Entity<AppData>,
    conversation_id: Uuid,
    /// The conversation as saved, once the engine has written it.
    conversation: Option<Conversation>,
    /// What the question asked from this window was limited to, until the
    /// saved conversation says it.
    asked_scope: Option<QuestionScope>,
    loaded_revision: Option<u64>,
    reloads_started: u64,
    reload_applied: u64,
    screens: ScreenCitations,
    loading_screens: HashSet<i64>,
    loading_files: HashSet<i64>,
    loading_notes: HashSet<String>,
    /// Cited meetings' transcripts, for the quoted line; `None` while loading.
    transcripts: HashMap<Uuid, Option<Rc<TranscriptLines>>>,
    answers: HashMap<Uuid, (u64, Rc<Answer>)>,
    scroll: ScrollHandle,
    last_stream_len: usize,
    _subscriptions: Vec<Subscription>,
}

/// A transcript's lines with the speakers' display names.
pub struct TranscriptLines {
    segments: Vec<Segment>,
    names: HashMap<String, String>,
}

impl TranscriptLines {
    /// The line said at `seconds`: the last one that started by then
    /// (`CitationPassage.line(at:)`).
    fn line_at(&self, seconds: f64) -> Option<(String, String)> {
        let segment = self
            .segments
            .iter()
            .rev()
            .find(|segment| segment.start <= seconds + 0.5)
            .or_else(|| self.segments.first())?;
        let speaker = self
            .names
            .get(&segment.speaker)
            .cloned()
            .unwrap_or_else(|| segment.speaker.clone());
        Some((
            search::speaker_label(&speaker),
            Transcript::display_text(&segment.text),
        ))
    }
}

impl EventEmitter<AnswerEvent> for QuickRecallAnswer {}

impl QuickRecallAnswer {
    pub fn new(
        conversation_id: Uuid,
        asked_scope: Option<QuestionScope>,
        cx: &mut Context<Self>,
    ) -> Self {
        let data = AppData::global(cx);
        let subscriptions = vec![cx.observe(&data, |this, _, cx| this.on_data_changed(cx))];
        let mut view = Self {
            data,
            conversation_id,
            conversation: None,
            asked_scope,
            loaded_revision: None,
            reloads_started: 0,
            reload_applied: 0,
            screens: ScreenCitations::default(),
            loading_screens: HashSet::new(),
            loading_files: HashSet::new(),
            loading_notes: HashSet::new(),
            transcripts: HashMap::new(),
            answers: HashMap::new(),
            scroll: ScrollHandle::new(),
            last_stream_len: 0,
            _subscriptions: subscriptions,
        };
        view.reload(cx);
        view
    }

    pub fn conversation_id(&self) -> Uuid {
        self.conversation_id
    }

    fn on_data_changed(&mut self, cx: &mut Context<Self>) {
        let (revision, stream_len) = {
            let data = self.data.read(cx);
            let stream = data
                .ask_stream
                .as_ref()
                .filter(|stream| stream.conversation_id == self.conversation_id);
            (
                data.revision,
                stream.map_or(0, |s| s.text.len() + s.activity.len()),
            )
        };
        if self.loaded_revision != Some(revision) {
            self.reload(cx);
        }
        // The answer keeps its end in view while it is written.
        if stream_len != self.last_stream_len {
            self.scroll.scroll_to_bottom();
        }
        self.last_stream_len = stream_len;
        cx.notify();
    }

    /// Reads the saved conversation off the UI thread. A read that started
    /// earlier and finished later is out of date.
    fn reload(&mut self, cx: &mut Context<Self>) {
        let library = self.data.read(cx).library.clone();
        self.loaded_revision = Some(self.data.read(cx).revision);
        self.reloads_started += 1;
        let reload = self.reloads_started;
        let id = self.conversation_id;
        cx.spawn(async move |this, cx| {
            let found = cx
                .background_spawn(async move {
                    library
                        .load_conversations()
                        .conversations
                        .into_iter()
                        .find(|conversation| conversation.id == id)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if reload <= this.reload_applied {
                    return;
                }
                this.reload_applied = reload;
                let grew = found.as_ref().map(|c| c.messages.len())
                    != this.conversation.as_ref().map(|c| c.messages.len());
                this.conversation = found;
                if grew {
                    this.scroll.scroll_to_bottom();
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// What a follow-up asks within: the latest question's scope
    /// (`currentQuestionScope`). `None` until it is known, rather than a wider
    /// guess.
    pub fn follow_up_scope(&self) -> Option<AskScope> {
        self.current_scope().map(|saved| scope::scope_for(&saved))
    }

    fn current_scope(&self) -> Option<QuestionScope> {
        self.conversation
            .as_ref()
            .and_then(|conversation| QuestionScope::current(&conversation.messages))
            .or_else(|| self.asked_scope.clone())
    }

    /// A follow-up was sent within `scope`.
    pub fn asked(&mut self, scope: QuestionScope, cx: &mut Context<Self>) {
        self.asked_scope = Some(scope);
        self.scroll.scroll_to_bottom();
        cx.notify();
    }

    /// The text of the answer that ends the conversation, once it is written
    /// (`QuickRecallAnswerFoot.latestAnswer`).
    pub fn latest_answer(&self, cx: &App) -> Option<String> {
        if self
            .data
            .read(cx)
            .ask_stream
            .as_ref()
            .is_some_and(|s| s.conversation_id == self.conversation_id)
        {
            return None;
        }
        let message = self.conversation.as_ref()?.messages.last()?;
        if message.role != ChatRole::Assistant
            || message.is_error
            || message.remember_receipt.is_some()
        {
            return None;
        }
        let text = citations::display_text(&message.text).trim().to_string();
        (!text.is_empty() && !is_stopped(&text)).then_some(text)
    }

    /// A "Remember …" receipt was saved without any model, so the foot names
    /// no place.
    pub fn ends_with_receipt(&self) -> bool {
        self.conversation
            .as_ref()
            .and_then(|c| c.messages.last())
            .is_some_and(|m| m.remember_receipt.is_some())
    }

    /// What the last question was limited to: "All sources", one meeting's
    /// title, or how many meetings and screen moments.
    pub fn scope_label(&self, cx: &App) -> Option<String> {
        let data = self.data.read(cx);
        let saved = self.current_scope()?;
        Some(model::scope_label(
            &saved,
            Offered::new(&data.settings),
            |id| {
                data.meetings
                    .iter()
                    .find(|meeting| meeting.id == id)
                    .map(|meeting| meeting.display_title())
            },
        ))
    }

    fn turns(&self, cx: &App) -> Vec<Turn> {
        let data = self.data.read(cx);
        let stream = data
            .ask_stream
            .as_ref()
            .filter(|s| s.conversation_id == self.conversation_id);
        let messages = self
            .conversation
            .as_ref()
            .map(|c| c.messages.as_slice())
            .unwrap_or(&[]);
        let mut turns = Vec::new();
        let mut question = String::new();
        for message in messages {
            match message.role {
                ChatRole::User => {
                    question = message.text.clone();
                    turns.push(Turn::Question {
                        text: message.text.clone(),
                        created_at: message
                            .created_at
                            .filter(|_| !message.created_at_is_estimated),
                        first: turns.is_empty(),
                    });
                }
                ChatRole::Assistant => turns.push(Turn::Answer {
                    id: message.id,
                    text: message.text.clone(),
                    step: None,
                    pending: false,
                    status: None,
                    error: message.is_error.then(|| message.text.clone()),
                    receipt: message.remember_receipt.is_some(),
                    used_claims: message.used_claim_ids.as_ref().map_or(0, Vec::len),
                    question: question.clone(),
                }),
            }
        }
        if let Some(stream) = stream {
            let saved_question = messages
                .last()
                .is_some_and(|m| m.role == ChatRole::User && m.text == stream.question);
            if !saved_question {
                turns.push(Turn::Question {
                    text: stream.question.clone(),
                    created_at: Some(Utc::now()),
                    first: turns.is_empty(),
                });
            }
            let answering = stream.error.is_none();
            turns.push(Turn::Answer {
                id: STREAM_ID,
                text: stream.text.clone(),
                step: stream
                    .activity
                    .last()
                    .filter(|_| answering && stream.text.is_empty())
                    .cloned(),
                pending: answering,
                status: stream.status.clone(),
                error: stream.error.as_ref().map(|e| e.to_string()),
                receipt: false,
                used_claims: 0,
                question: stream.question.clone(),
            });
        }
        turns
    }

    fn parsed(&mut self, id: Uuid, text: &str) -> Rc<Answer> {
        let mut hasher = DefaultHasher::new();
        text.hash(&mut hasher);
        let hash = hasher.finish();
        if let Some((cached, answer)) = self.answers.get(&id)
            && *cached == hash
        {
            return answer.clone();
        }
        let answer = Rc::new(answer_text::parse(text));
        self.answers.insert(id, (hash, answer.clone()));
        answer
    }

    // -------------------------------------------------------------- sources

    /// Reads what the citations point at and is not known yet, off the UI
    /// thread. Files and agent notes resolve only while their own settings
    /// are on, as on the Ask screen.
    fn load_sources(&mut self, sources: &[CitationSource], cx: &mut Context<Self>) {
        let (library, root, files_on, notes_on, meetings) = {
            let data = self.data.read(cx);
            (
                data.library.clone(),
                data.library.paths().root().to_path_buf(),
                data.settings.file_search_enabled,
                data.settings.coding_agent_notes_enabled,
                data.meetings.clone(),
            )
        };
        let screens: Vec<i64> = sources
            .iter()
            .filter_map(|source| match source {
                CitationSource::Screen { snapshot_id } => Some(*snapshot_id),
                _ => None,
            })
            .filter(|id| !self.screens.contains_key(id) && self.loading_screens.insert(*id))
            .collect();
        let files: Vec<i64> = sources
            .iter()
            .filter_map(|source| match source {
                CitationSource::File { id } => Some(*id),
                _ => None,
            })
            .filter(|id| citations::known_file_citation(*id).is_none())
            .filter(|id| self.loading_files.insert(*id))
            .collect();
        let notes: Vec<String> = sources
            .iter()
            .filter_map(|source| match source {
                CitationSource::Note { id } => Some(id.clone()),
                _ => None,
            })
            .filter(|id| citations::known_note_citation(id).is_none())
            .filter(|id| self.loading_notes.insert(id.clone()))
            .collect();
        let transcripts: Vec<lokalbot_core::Meeting> = sources
            .iter()
            .filter(|source| matches!(source, CitationSource::Meeting { at: Some(_), .. }))
            .filter_map(|source| source.meeting(&meetings).cloned())
            .filter(|meeting| !self.transcripts.contains_key(&meeting.id))
            .collect();
        for meeting in &transcripts {
            self.transcripts.insert(meeting.id, None);
        }
        if screens.is_empty() && files.is_empty() && notes.is_empty() && transcripts.is_empty() {
            return;
        }
        cx.spawn(async move |this, cx| {
            let (screens, lines) = cx
                .background_spawn(async move {
                    let screens: Vec<(i64, Option<lokalbot_core::ScreenMoment>)> = screens
                        .into_iter()
                        .map(|id| (id, library.screen_moment(id).ok().flatten()))
                        .collect();
                    if !files.is_empty() {
                        let reader = lokalbot_core::files::search::FileReader::shared(&root);
                        for id in files {
                            citations::remember_file_citation(
                                id,
                                files_on.then(|| reader.hit(id)).flatten(),
                            );
                        }
                    }
                    if !notes.is_empty() {
                        let index = lokalbot_core::agent_notes::NotesIndex::new(&root);
                        for id in notes {
                            let hit = notes_on.then(|| index.hit(&id).ok().flatten()).flatten();
                            citations::remember_note_citation(&id, hit);
                        }
                    }
                    let lines: Vec<(Uuid, Option<TranscriptLines>)> = transcripts
                        .into_iter()
                        .map(|meeting| {
                            let lines =
                                library
                                    .transcript(&meeting)
                                    .ok()
                                    .flatten()
                                    .map(|transcript| {
                                        let names = transcript
                                            .segments
                                            .iter()
                                            .map(|s| {
                                                (
                                                    s.speaker.clone(),
                                                    transcript.speaker_name(&s.speaker),
                                                )
                                            })
                                            .collect();
                                        TranscriptLines {
                                            segments: transcript.segments,
                                            names,
                                        }
                                    });
                            (meeting.id, lines)
                        })
                        .collect();
                    (screens, lines)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                for (id, moment) in screens {
                    this.loading_screens.remove(&id);
                    this.screens.insert(id, moment);
                }
                for (id, lines) in lines {
                    // A transcript that can't be read leaves the line empty.
                    this.transcripts.insert(
                        id,
                        Some(Rc::new(lines.unwrap_or(TranscriptLines {
                            segments: Vec::new(),
                            names: HashMap::new(),
                        }))),
                    );
                }
                cx.notify();
            });
        })
        .detach();
    }

    /// What a source row shows, and whether it can be opened.
    fn source(&self, citation: &CitationSource, question: &str, cx: &App) -> Source {
        let data = self.data.read(cx);
        let quote = |text: Option<&str>| {
            text.and_then(|text| model::quote_line(text, question, QUOTE_LIMIT))
        };
        match citation {
            CitationSource::Meeting { at, .. } => match citation.meeting(&data.meetings) {
                Some(meeting) => {
                    let line = at.and_then(|at| {
                        self.transcripts
                            .get(&meeting.id)
                            .cloned()
                            .flatten()
                            .and_then(|lines| lines.line_at(at))
                    });
                    Source {
                        title: meeting.display_title(),
                        qualifier: None,
                        when: Some(meeting.started_at),
                        at: *at,
                        speaker: line.as_ref().map(|(speaker, _)| speaker.clone()),
                        line: quote(line.as_ref().map(|(_, text)| text.as_str())),
                        available: true,
                    }
                }
                None => Source::missing("Meeting"),
            },
            CitationSource::Screen { snapshot_id } => match self.screens.get(snapshot_id) {
                Some(Some(moment)) => Source {
                    title: if moment.window_title.trim().is_empty() {
                        moment.app.clone()
                    } else {
                        moment.window_title.clone()
                    },
                    qualifier: (!moment.window_title.trim().is_empty()).then(|| moment.app.clone()),
                    when: Some(moment.ts),
                    at: None,
                    speaker: None,
                    line: quote(moment.text.as_deref()),
                    available: true,
                },
                _ => Source::missing("Screen"),
            },
            CitationSource::File { id } => match citations::known_file_citation(*id) {
                Some(Some(hit)) if data.settings.file_search_enabled => Source {
                    title: hit.name(),
                    qualifier: Some(hit.folder()),
                    when: Some(hit.date()),
                    at: None,
                    speaker: hit.excerpt.as_ref().and_then(|_| rows::file_lead(&hit)),
                    line: quote(hit.excerpt.as_deref().map(strip_marks).as_deref()),
                    available: true,
                },
                _ => Source::missing("Files"),
            },
            CitationSource::Note { id } => match citations::known_note_citation(id) {
                Some(Some(hit)) if data.settings.coding_agent_notes_enabled => Source {
                    title: hit.title.clone(),
                    qualifier: Some(hit.source_label()),
                    when: Some(hit.modified),
                    at: None,
                    speaker: None,
                    line: quote(
                        hit.summary
                            .as_deref()
                            .or(Some(hit.snippet.as_str()))
                            .map(strip_marks)
                            .as_deref(),
                    ),
                    available: true,
                },
                _ => Source::missing("Agent note"),
            },
        }
    }

    fn open(&mut self, citation: &CitationSource, cx: &mut Context<Self>) {
        let data = self.data.clone();
        let opened_in_main = match citation {
            CitationSource::Meeting { at, .. } => {
                let meetings = data.read(cx).meetings.clone();
                let Some(meeting) = citation.meeting(&meetings) else {
                    return;
                };
                let (id, at) = (meeting.id, *at);
                let tab = if at.is_some() {
                    MeetingTab::Transcript
                } else {
                    MeetingTab::Summary
                };
                data.update(cx, |data, cx| data.open_meeting(id, tab, at, cx));
                true
            }
            CitationSource::Screen { snapshot_id } => {
                let Some(Some(moment)) = self.screens.get(snapshot_id).cloned() else {
                    return;
                };
                crate::pages::ask::open_screen_moment(&data, &moment, cx);
                true
            }
            CitationSource::File { id } => {
                let Some(Some(hit)) = citations::known_file_citation(*id) else {
                    return;
                };
                if !data.read(cx).settings.file_search_enabled {
                    return;
                }
                search::open_file(&hit);
                false
            }
            CitationSource::Note { id } => {
                let Some(Some(hit)) = citations::known_note_citation(id) else {
                    return;
                };
                if !data.read(cx).settings.coding_agent_notes_enabled {
                    return;
                }
                search::open_note(&hit);
                false
            }
        };
        cx.emit(AnswerEvent::Opened {
            in_main_window: opened_in_main,
        });
    }

    // -------------------------------------------------------------- drawing

    fn render_question(
        &self,
        text: String,
        created_at: Option<DateTime<Utc>>,
        first: bool,
        cx: &App,
    ) -> Div {
        let lb = cx.lb();
        let you = lokalbot_i18n::tr("You").to_string();
        let asked = match created_at {
            Some(at) => format!(
                "{you} · {}",
                at.with_timezone(&Local).format_localized(
                    lokalbot_i18n::date_pattern("%-I:%M %p"),
                    lokalbot_i18n::date_locale()
                )
            ),
            None => you,
        };
        v_flex()
            .gap(px(4.))
            .when(!first, |this| this.child(ui::divider(cx).mb(px(8.))))
            .child(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(asked),
            )
            .child(
                div()
                    .text_size(ty::COLUMN_TITLE)
                    .line_height(px(22.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text)
                    .text_align(crate::i18n::content_alignment(&text))
                    .child(ui::text::paragraph(text)),
            )
    }

    #[allow(clippy::too_many_arguments)]
    fn render_answer(
        &mut self,
        id: Uuid,
        text: String,
        step: Option<String>,
        pending: bool,
        status: Option<SharedString>,
        error: Option<String>,
        receipt: bool,
        used_claims: usize,
        question: String,
        cx: &mut Context<Self>,
    ) -> Div {
        let lb = cx.lb().clone();
        let column = v_flex().gap(px(12.)).w_full();
        if receipt {
            // A "Remember …" statement saved as said, without any model.
            return column.child(
                div()
                    .text_size(ty::BODY)
                    .text_color(lb.text_secondary)
                    .child(ui::text::paragraph(text)),
            );
        }
        if is_stopped(&text) {
            return column.child(status_card(
                lokalbot_i18n::tr("Response stopped"),
                None,
                Ico::CircleStop,
                lb.text_secondary,
                cx,
            ));
        }
        if let Some(error) = error {
            return column.child(status_card(
                lokalbot_i18n::tr("Couldn't answer"),
                Some(error),
                Ico::TriangleAlert,
                lb.attention_text,
                cx,
            ));
        }
        if pending && text.trim().is_empty() {
            let title = step
                .map(SharedString::from)
                .or(status)
                .unwrap_or_else(|| lokalbot_i18n::tr("Preparing the assistant").into());
            return column.child(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(Spinner::new().xsmall().color(lb.text_secondary))
                    .child(title),
            );
        }
        let answer = self.parsed(id, &text);
        let view = cx.entity();
        let cited = answer.citations.clone();
        let on_cite: answer_text::CiteHandler = Rc::new(move |index, _, cx| {
            if let Some(source) = cited.get(index).cloned() {
                view.update(cx, |view, cx| view.open(&source, cx));
            }
        });
        let mut column = column.child(answer_text::render(
            ("quick-recall-answer", element_key(id)),
            &answer,
            AnswerStyle::editorial(cx),
            on_cite,
            cx,
        ));
        if !pending && !answer.citations.is_empty() {
            self.load_sources(&answer.citations, cx);
            column = column.child(self.render_sources(id, &answer.citations, &question, cx));
        }
        if !pending && used_claims > 0 {
            let label = if used_claims == 1 {
                lokalbot_i18n::tr("Used 1 thing you told LokalBot").to_string()
            } else {
                lokalbot_i18n::format(
                    "Used {0} things you told LokalBot",
                    &[("0", used_claims.to_string())],
                )
            };
            column = column.child(
                h_flex()
                    .gap(px(6.))
                    .items_center()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(ui::icon(Ico::UserRoundCheck, px(13.), lb.text_secondary))
                    .child(model::directional(label)),
            );
        }
        column
    }

    /// The sources under an answer: a row per citation, numbered as in the
    /// answer (`QuickRecallAnswerSources`).
    fn render_sources(
        &self,
        answer_id: Uuid,
        sources: &[CitationSource],
        question: &str,
        cx: &mut Context<Self>,
    ) -> Div {
        let lb = cx.lb().clone();
        let colors = RowColors::new(false, cx);
        let key = element_key(answer_id);
        let rows: Vec<AnyElement> = sources
            .iter()
            .enumerate()
            .map(|(index, citation)| {
                let source = self.source(citation, question, cx);
                let accessory = source.at.map(|at| {
                    div()
                        .flex_none()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.accent_text)
                        .child(format!("▶ {}", ui::action_row::short_stamp(at)))
                });
                let when = source.when.map(|at| model::date_label(at, Local::now()));
                let citation = citation.clone();
                h_flex()
                    .id(("quick-recall-source", key.wrapping_add(index as u64)))
                    .w_full()
                    .items_start()
                    .gap(px(10.))
                    .px(px(10.))
                    .py(px(5.))
                    .rounded(metric::ROW_RADIUS)
                    .when(source.available, |this| {
                        this.cursor_pointer()
                            .hover(|s| s.bg(lb.text.opacity(0.05)))
                            .on_click(cx.listener(move |this, _, _, cx| this.open(&citation, cx)))
                    })
                    .child(
                        div()
                            .mt(px(1.))
                            .flex_none()
                            .size(px(18.))
                            .rounded_full()
                            .bg(lb.accent_fill.opacity(0.12))
                            .flex()
                            .items_center()
                            .justify_center()
                            .text_size(ty::CAPTION)
                            .font_weight(FontWeight::BOLD)
                            .text_color(lb.accent_text)
                            .child(lokalbot_i18n::number(index + 1)),
                    )
                    .child(rows::row_text(
                        &source.title,
                        accessory,
                        source.qualifier.as_deref(),
                        when,
                        source.speaker.as_deref(),
                        source.line.as_deref(),
                        RowColors {
                            strong: if source.available {
                                colors.strong
                            } else {
                                colors.quiet
                            },
                            quiet: colors.quiet,
                        },
                    ))
                    .into_any_element()
            })
            .collect();
        v_flex()
            .w_full()
            .child(
                div()
                    .pb(px(3.))
                    .text_size(ty::CAPTION)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text_secondary)
                    .child(lokalbot_i18n::tr("Sources")),
            )
            .child(v_flex().mx(px(-10.)).children(rows))
    }
}

/// What a source row shows.
struct Source {
    title: String,
    qualifier: Option<String>,
    when: Option<DateTime<Utc>>,
    /// A meeting citation's moment.
    at: Option<f64>,
    speaker: Option<String>,
    line: Option<String>,
    available: bool,
}

impl Source {
    /// A source still loading, gone from this computer, or not read now: its
    /// kind's name, and nothing to open (`placeholderTitle`).
    fn missing(kind: &'static str) -> Self {
        Self {
            title: lokalbot_i18n::tr(kind).to_string(),
            qualifier: None,
            when: None,
            at: None,
            speaker: None,
            line: None,
            available: false,
        }
    }
}

/// A number for element ids made from a turn's id.
fn element_key(id: Uuid) -> u64 {
    let (high, low) = id.as_u64_pair();
    high ^ low
}

/// A stopped turn's text (`isStoppedTurn`).
fn is_stopped(text: &str) -> bool {
    let normalized = text.trim().to_lowercase();
    normalized == "stopped." || normalized.starts_with("response stopped")
}

/// A search excerpt's «» marks, so the quote marks the question's words instead.
fn strip_marks(text: &str) -> String {
    text.replace(['«', '»'], "")
}

/// A short notice in place of an answer.
fn status_card(
    title: &str,
    detail: Option<String>,
    icon: Ico,
    tint: gpui_kit::Hsla,
    cx: &App,
) -> Div {
    let lb = cx.lb();
    h_flex()
        .gap(px(10.))
        .items_start()
        .p(px(10.))
        .rounded(metric::GROUP_RADIUS)
        .bg(lb.group_fill)
        .border_1()
        .border_color(lb.group_stroke)
        .child(ui::icon(icon, px(16.), tint))
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
                        .child(title.to_string()),
                )
                .when_some(detail, |this, detail| {
                    this.child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(ui::text::paragraph(detail)),
                    )
                }),
        )
}

impl Render for QuickRecallAnswer {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let turns = self.turns(cx);
        let mut elements: Vec<AnyElement> = Vec::new();
        for turn in turns {
            elements.push(match turn {
                Turn::Question {
                    text,
                    created_at,
                    first,
                } => self
                    .render_question(text, created_at, first, cx)
                    .into_any_element(),
                Turn::Answer {
                    id,
                    text,
                    step,
                    pending,
                    status,
                    error,
                    receipt,
                    used_claims,
                    question,
                } => self
                    .render_answer(
                        id,
                        text,
                        step,
                        pending,
                        status,
                        error,
                        receipt,
                        used_claims,
                        question,
                        cx,
                    )
                    .into_any_element(),
            });
        }
        div()
            .id("quick-recall-answer")
            .size_full()
            .overflow_y_scroll()
            .track_scroll(&self.scroll)
            .child(
                v_flex()
                    .w_full()
                    .px(px(24.))
                    .pt(px(14.))
                    .pb(px(14.))
                    .gap(px(16.))
                    .children(elements),
            )
    }
}
