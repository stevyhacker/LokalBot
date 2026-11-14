//! Meetings: the library list beside the meeting workspace
//! (`MeetingListView.swift`, `MeetingWorkspaceView.swift`,
//! `LiveMeetingDetailView.swift`).

mod detail;
pub(crate) mod dialogs;
pub(crate) mod follow_up;
pub(crate) mod list;
mod live;
pub mod model;
mod naming;
mod page_search;
mod playback;
mod presentation;
mod speaker_identity;
mod speaker_suggestions;
mod spoken;
mod transcript;

use crate::windows::screen_image::ScreenImage;
use gpui_kit::actions;
use std::cell::Cell;
use std::rc::Rc;
use std::time::Duration;

use crate::i18n::h_flex;
use gpui_kit::component::Icon;
use gpui_kit::component::WindowExt as _;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{InputEvent, InputState, TextareaState};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Bounds, ClipboardItem, Context, Entity, FocusHandle,
    Focusable as _, IntoElement, KeyBinding, ListAlignment, ListOffset, ListState,
    ParentElement as _, Pixels, Render, SharedString, Styled as _, Subscription, Task, Window,
    anchored, canvas, deferred, div, point, px,
};
use lokalbot_core::{ActionStatus, Meeting};
use uuid::Uuid;

use self::model::MeetingDoc;
use crate::pages::Page;
use crate::state::{AppData, AppEvent, AskRequest, MeetingTab, RecordingState};
use crate::theme::metric;
use crate::ui::{self, Ico, segmented_tabs};

/// Summary, Transcript and Notes. The Review tab is gone: its jobs are the
/// naming sheet, the owner menu on each action and the refresh banner.
const TABS: [&str; 3] = ["Summary", "Transcript", "Notes"];

fn tab_index(tab: MeetingTab) -> usize {
    match tab {
        MeetingTab::Summary => 0,
        MeetingTab::Transcript => 1,
        MeetingTab::Notes => 2,
    }
}

fn tab_at(index: usize) -> MeetingTab {
    match index {
        1 => MeetingTab::Transcript,
        2 => MeetingTab::Notes,
        _ => MeetingTab::Summary,
    }
}

/// One row of the meeting list.
#[derive(Clone)]
pub(crate) enum Entry {
    Header(SharedString),
    Meeting { meeting: Box<Meeting>, live: bool },
}

/// Notes save state shown beside "Your notes".
#[derive(Clone, PartialEq)]
pub(crate) enum NotesStatus {
    Saved,
    Saving,
    Failed(SharedString),
}

pub(crate) struct NotesEditor {
    pub input: Entity<TextareaState>,
    pub meeting: Option<Uuid>,
    pub saved: String,
    pub status: NotesStatus,
    pub save_task: Option<Task<()>>,
    /// Set while the editor's text is replaced programmatically.
    pub loading: bool,
}

pub(crate) struct FindBar {
    /// The overview's scroll position, moved to bring the current match in view.
    pub scroll: gpui_kit::ScrollHandle,
    /// The current match still needs bringing into view.
    pub reveal: std::rc::Rc<std::cell::Cell<bool>>,
    pub input: Entity<InputState>,
    /// Opened with Find; on the Transcript tab the bar is always shown.
    pub open: bool,
    pub query: String,
    /// Every occurrence in reading order.
    pub matches: Vec<page_search::PageMatch>,
    pub current: usize,
}

pub struct MeetingsPage {
    data: Entity<AppData>,
    list_focus: FocusHandle,
    search: Entity<InputState>,
    query: String,
    entries: Vec<Entry>,
    entries_key: Option<(u64, String, Option<Uuid>, bool, usize, u64)>,
    /// Meetings whose transcript or notes match the query (full-text, debounced).
    content_matches: std::collections::HashSet<Uuid>,
    content_generation: u64,
    content_task: Option<Task<()>>,
    list_state: ListState,
    /// The meeting the workspace shows.
    selected: Option<Uuid>,
    /// Every selected meeting, for merging and deleting several at once;
    /// just `selected` unless Ctrl- or Shift-clicked.
    selection: Vec<Uuid>,
    /// Where a Shift-click range starts.
    selection_anchor: Option<Uuid>,
    doc: Option<Rc<MeetingDoc>>,
    doc_loading: bool,
    load_generation: u64,
    loaded_revision: u64,
    tab: MeetingTab,
    /// Transcript moment to highlight and reveal (evidence, find).
    focus_at: Option<f64>,
    /// Transcript row of `focus_at`, computed once per render.
    focused_row: Option<usize>,
    pending_reveal: bool,
    recap_expanded: bool,
    full_notes_expanded: bool,
    transcript_state: ListState,
    find: FindBar,
    notes: NotesEditor,
    live_notes: NotesEditor,
    /// The live transcript list: follows new lines until the user scrolls up.
    live_scroll: gpui_kit::ScrollHandle,
    live_follow: bool,
    live_seen_lines: usize,
    hover: Option<f32>,
    playhead: f32,
    speed: f32,
    player: Option<std::sync::Arc<lokalbot_audio::Player>>,
    player_loading: bool,
    playing: bool,
    poll: Option<Task<()>>,
    page_bounds: Rc<Cell<Option<Bounds<Pixels>>>>,
    tick: Option<Task<()>>,
    /// Where each meeting's playback stood, for coming back to it.
    playback_memory: std::collections::HashMap<Uuid, (f64, f32)>,
    exporting_audio: bool,
    unmatched_expanded: bool,
    /// Small images of what was on screen, by snapshot. Decrypted pixels stay
    /// in memory for the meeting on the page.
    screen_thumbnails: Rc<std::cell::RefCell<std::collections::HashMap<i64, Option<ScreenImage>>>>,
    screen_thumbnails_for: Option<Uuid>,
    released_thumbnails: Vec<std::sync::Arc<gpui_kit::RenderImage>>,
    _subscriptions: Vec<Subscription>,
}

actions!(meetings, [FindOnMeetingPage]);

/// Ctrl+F opens Find from anywhere on the meeting page, whatever has focus or
/// nothing at all (`requestSelectedMeetingSearch`), so it can't live on one
/// element. A text field hands the shortcut on as its own `Search`.
fn bind_find(cx: &mut App) {
    fn request(cx: &mut App) {
        // Other windows keep the shortcut to themselves.
        let main = crate::desktop::desktop(cx).and_then(|d| *d.main_window.lock());
        if let (Some(main), Some(active)) = (main, cx.active_window())
            && main != active
        {
            return;
        }
        AppData::global(cx).update(cx, |data, cx| {
            if data.section == crate::state::Section::Meetings {
                data.meeting_find_requested = true;
                cx.notify();
            }
        });
    }
    cx.bind_keys([KeyBinding::new("ctrl-f", FindOnMeetingPage, None)]);
    cx.on_action(|_: &FindOnMeetingPage, cx: &mut App| request(cx));
    cx.on_action(|_: &gpui_kit::component::input::Search, cx: &mut App| request(cx));
}

impl MeetingsPage {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        bind_find(cx);
        let data = AppData::global(cx);
        let search = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                "Search meetings",
                window,
                cx,
            ))
        });
        let find_input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                "Find in transcript",
                window,
                cx,
            ))
        });
        let notes_input = cx.new(|cx| {
            TextareaState::new(window, cx)
                .rows(18)
                .placeholder(crate::i18n::placeholder(
                    "Add context, reminders, or your own wording. Notes save automatically.",
                    window,
                    cx,
                ))
        });
        let live_input = cx.new(|cx| {
            TextareaState::new(window, cx)
                .rows(12)
                .placeholder(crate::i18n::placeholder("Meeting notes", window, cx))
        });

        let mut subscriptions = vec![
            cx.observe_in(&data, window, |this, _, window, cx| {
                this.on_data_changed(window, cx);
                cx.notify();
            }),
            cx.subscribe_in(&search, window, |this, input, event: &InputEvent, _, cx| {
                if let InputEvent::Change = event {
                    this.query = input.read(cx).value().trim().to_string();
                    this.search_content(cx);
                    cx.notify();
                }
            }),
            cx.subscribe_in(
                &find_input,
                window,
                |this, input, event: &InputEvent, _, cx| match event {
                    InputEvent::Change => {
                        this.find.query = input.read(cx).value().to_string();
                        this.update_find_matches(true, cx);
                    }
                    InputEvent::PressEnter { shift, .. } => {
                        this.move_find(if *shift { -1 } else { 1 }, cx)
                    }
                    _ => {}
                },
            ),
        ];
        subscriptions.push(cx.subscribe_in(
            &notes_input,
            window,
            |this, _, event: &InputEvent, _, cx| {
                if let InputEvent::Change = event {
                    this.schedule_notes_save(false, cx);
                }
            },
        ));
        subscriptions.push(cx.subscribe_in(
            &live_input,
            window,
            |this, _, event: &InputEvent, _, cx| {
                if let InputEvent::Change = event {
                    this.schedule_notes_save(true, cx);
                }
            },
        ));

        let mut this = Self {
            data,
            list_focus: cx.focus_handle(),
            search,
            query: String::new(),
            entries: Vec::new(),
            entries_key: None,
            content_matches: Default::default(),
            content_generation: 0,
            content_task: None,
            list_state: ListState::new(0, ListAlignment::Top, px(400.)),
            selected: None,
            selection: Vec::new(),
            selection_anchor: None,
            doc: None,
            doc_loading: false,
            load_generation: 0,
            loaded_revision: 0,
            tab: MeetingTab::Summary,
            focus_at: None,
            focused_row: None,
            pending_reveal: false,
            recap_expanded: false,
            full_notes_expanded: false,
            transcript_state: ListState::new(0, ListAlignment::Top, px(600.)),
            find: FindBar {
                scroll: gpui_kit::ScrollHandle::new(),
                reveal: Default::default(),
                input: find_input,
                open: false,
                query: String::new(),
                matches: Vec::new(),
                current: 0,
            },
            notes: NotesEditor {
                input: notes_input,
                meeting: None,
                saved: String::new(),
                status: NotesStatus::Saved,
                save_task: None,
                loading: false,
            },
            live_notes: NotesEditor {
                input: live_input,
                meeting: None,
                saved: String::new(),
                status: NotesStatus::Saved,
                save_task: None,
                loading: false,
            },
            live_scroll: gpui_kit::ScrollHandle::new(),
            live_follow: true,
            live_seen_lines: 0,
            hover: None,
            playhead: 0.,
            speed: 1.,
            player: None,
            player_loading: false,
            playing: false,
            poll: None,
            page_bounds: Rc::new(Cell::new(None)),
            tick: None,
            playback_memory: Default::default(),
            exporting_audio: false,
            unmatched_expanded: false,
            screen_thumbnails: Default::default(),
            screen_thumbnails_for: None,
            released_thumbnails: Vec::new(),
            _subscriptions: subscriptions,
        };
        this.on_data_changed(window, cx);
        this
    }

    // ------------------------------------------------------------ data flow

    /// Applies navigation requests and reloads after library changes.
    /// The palette's "Draft follow-up" opens the sheet once the meeting is showing.
    fn open_requested_follow_up(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let wanted = self.data.read(cx).follow_up_request;
        if wanted.is_some() && wanted == self.doc.as_ref().map(|doc| doc.meeting.id) {
            self.data
                .update(cx, |data, _| data.follow_up_request = None);
            self.open_follow_up(window, cx);
        }
    }

    fn on_data_changed(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.open_requested_follow_up(window, cx);
        let focus = self.data.update(cx, |data, _| data.meeting_focus.take());
        if let Some(focus) = focus {
            self.tab = focus.tab;
            self.focus_at = focus.at;
            self.pending_reveal = focus.at.is_some();
            self.selection = vec![focus.meeting_id];
            self.selection_anchor = Some(focus.meeting_id);
            if self.selected != Some(focus.meeting_id) {
                self.selected = Some(focus.meeting_id);
                self.doc_loading = true;
                self.load_doc(window, cx);
            } else {
                // The meeting is already open (a citation from Ask about the
                // meeting shown before): no load follows to reveal the moment.
                self.reveal_focus();
            }
            if focus.tab == MeetingTab::Transcript && focus.at.is_some() {
                self.find.open = false;
            }
            cx.notify();
        }
        if self.playing && self.data.read(cx).section != crate::state::Section::Meetings {
            self.pause_playback();
        }
        let revision = self.data.read(cx).revision;
        if revision != self.loaded_revision {
            self.loaded_revision = revision;
            self.ensure_selection(window, cx);
            self.load_doc(window, cx);
        }
    }

    /// Selects the newest meeting when nothing (or a deleted meeting) is selected.
    fn ensure_selection(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let data = self.data.read(cx);
        if !data.meetings_loaded {
            return;
        }
        let live = data.recording.meeting().map(|m| m.id);
        self.selection
            .retain(|id| data.meeting(*id).is_some() || Some(*id) == live);
        let exists = self
            .selected
            .is_some_and(|id| data.meeting(id).is_some() || Some(id) == live);
        if !exists {
            self.selected = live.or_else(|| data.meetings.first().map(|m| m.id));
            self.selection = self.selected.into_iter().collect();
            self.selection_anchor = self.selected;
            self.doc = None;
            self.doc_loading = self.selected.is_some();
            self.load_doc(window, cx);
        }
    }

    fn selected_meeting(&self, cx: &App) -> Option<Meeting> {
        let id = self.selected?;
        let data = self.data.read(cx);
        data.recording
            .meeting()
            .filter(|m| m.id == id)
            .cloned()
            .or_else(|| data.meeting(id).cloned())
    }

    fn is_live_selected(&self, cx: &App) -> bool {
        let data = self.data.read(cx);
        matches!(&data.recording, RecordingState::Recording { meeting, .. } if Some(meeting.id) == self.selected)
    }

    pub(crate) fn select(&mut self, id: Uuid, window: &mut Window, cx: &mut Context<Self>) {
        if self.selection != [id] {
            self.selection = vec![id];
            cx.notify();
        }
        self.selection_anchor = Some(id);
        self.show(id, window, cx);
    }

    /// A row click: Ctrl (Cmd on macOS) adds or removes one meeting, Shift
    /// selects the rows from the last plain click, anything else selects one.
    pub(crate) fn click_row(
        &mut self,
        id: Uuid,
        modifiers: gpui_kit::Modifiers,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let live = self.data.read(cx).recording.meeting().map(|m| m.id);
        if Some(id) == live || !(modifiers.control || modifiers.platform || modifiers.shift) {
            self.select(id, window, cx);
            return;
        }
        if modifiers.shift {
            let ids = self.meeting_ids();
            let anchor = self.selection_anchor.unwrap_or(id);
            let (Some(from), Some(to)) = (
                ids.iter().position(|m| *m == anchor),
                ids.iter().position(|m| *m == id),
            ) else {
                self.select(id, window, cx);
                return;
            };
            let (from, to) = (from.min(to), from.max(to));
            self.selection = ids[from..=to]
                .iter()
                .copied()
                .filter(|m| Some(*m) != live)
                .collect();
        } else if let Some(at) = self.selection.iter().position(|m| *m == id) {
            if self.selection.len() == 1 {
                return;
            }
            self.selection.remove(at);
            if self.selected == Some(id)
                && let Some(last) = self.selection.last().copied()
            {
                self.show(last, window, cx);
            }
            cx.notify();
            return;
        } else {
            self.selection.retain(|m| Some(*m) != live);
            self.selection.push(id);
            self.selection_anchor = Some(id);
        }
        self.show(id, window, cx);
        cx.notify();
    }

    /// The selected meetings that exist, in list order.
    pub(crate) fn selected_meetings(&self, cx: &App) -> Vec<Meeting> {
        let data = self.data.read(cx);
        data.meetings
            .iter()
            .filter(|m| self.selection.contains(&m.id))
            .cloned()
            .collect()
    }

    /// Shows one meeting in the workspace without changing the selection.
    fn show(&mut self, id: Uuid, window: &mut Window, cx: &mut Context<Self>) {
        if self.selected == Some(id) {
            return;
        }
        self.flush_notes(cx);
        self.remember_playback();
        self.stop_playback();
        self.stop_spoken_summary(cx);
        self.selected = Some(id);
        self.focus_at = None;
        self.recap_expanded = false;
        self.full_notes_expanded = false;
        self.playhead = 0.;
        self.speed = self
            .playback_memory
            .get(&id)
            .map_or(1., |(_, speed)| *speed);
        self.hover = None;
        self.doc_loading = true;
        self.load_doc(window, cx);
        cx.notify();
    }

    fn load_doc(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(meeting) = self.selected_meeting(cx) else {
            self.doc = None;
            self.doc_loading = false;
            return;
        };
        let library = self.data.read(cx).library.clone();
        self.load_generation += 1;
        let generation = self.load_generation;
        cx.spawn_in(window, async move |this, cx| {
            let doc = cx
                .background_spawn(async move { model::load(&library, meeting) })
                .await;
            let _ = this.update_in(cx, |this, window, cx| {
                if this.load_generation != generation {
                    return;
                }
                let switched = this.doc.as_ref().map(|d| d.meeting.id) != Some(doc.meeting.id);
                // A recording that just ended has new audio: a player opened
                // while it was still being written knows only its first part.
                let audio_changed = this.doc.as_ref().is_some_and(|d| {
                    d.meeting.ended_at != doc.meeting.ended_at || d.has_audio != doc.has_audio
                });
                let doc = Rc::new(doc);
                if switched || this.transcript_state.item_count() != doc.rows.len() + 1 {
                    this.transcript_state.reset(doc.rows.len() + 1);
                }
                this.doc = Some(doc);
                this.doc_loading = false;
                if switched {
                    this.load_notes_editor(window, cx);
                }
                if switched || audio_changed {
                    this.open_player(cx);
                }
                if switched && doc_has_journal(&this.doc) {
                    this.recover_saved_names(cx);
                }
                this.update_find_matches(false, cx);
                this.reveal_focus();
                cx.notify();
            });
        })
        .detach();
    }

    fn remember_playback(&mut self) {
        if let (Some(id), Some(player)) = (self.selected, self.player.as_ref()) {
            self.playback_memory
                .insert(id, (player.position(), self.speed));
        }
    }

    /// A name recorded just before a crash still reaches the transcript.
    fn recover_saved_names(&mut self, cx: &mut Context<Self>) {
        let Some(doc) = self.doc.clone() else { return };
        let library = self.data.read(cx).library.clone();
        let meeting = doc.meeting.clone();
        let data = self.data.clone();
        cx.spawn(async move |_, cx| {
            let changed = cx
                .background_spawn(async move {
                    lokalbot_engine::voice::recover_saved_names(&library, &meeting)
                })
                .await;
            match changed {
                Ok(true) => {
                    data.update(cx, |data, cx| data.mark_library_changed(cx));
                }
                Ok(false) => {}
                Err(err) => log::info!("speaker names not recovered: {err:#}"),
            }
        })
        .detach();
    }

    /// Scrolls the transcript to the focused moment once its rows exist.
    fn reveal_focus(&mut self) {
        if !self.pending_reveal || self.tab != MeetingTab::Transcript {
            return;
        }
        let Some(doc) = self.doc.as_ref() else { return };
        if let Some(row) = self.focus_at.and_then(|at| doc.row_at(at)) {
            // Item 0 is the header, so row r is item r + 1. Rows the list has
            // not drawn yet (the transcript tab was not open) have no height,
            // and revealing them would not move: put the row before it at
            // the top instead.
            if self.transcript_state.bounds_for_item(row + 1).is_some() {
                self.transcript_state.scroll_to_reveal_item(row + 1);
            } else {
                self.transcript_state.scroll_to(ListOffset {
                    item_ix: row,
                    offset_in_item: px(0.),
                });
            }
            self.pending_reveal = false;
        }
    }

    pub(crate) fn set_tab(&mut self, tab: MeetingTab, cx: &mut Context<Self>) {
        if self.tab == tab {
            return;
        }
        if self.tab == MeetingTab::Transcript && tab != MeetingTab::Transcript && !self.find.open {
            self.find.matches.clear();
        }
        self.tab = tab;
        self.reveal_focus();
        cx.notify();
    }

    /// Opens the transcript at `seconds`, highlighting that passage.
    pub(crate) fn show_evidence(&mut self, seconds: f64, cx: &mut Context<Self>) {
        self.tab = MeetingTab::Transcript;
        self.focus_at = Some(seconds);
        self.pending_reveal = true;
        if let Some(doc) = self.doc.as_ref() {
            let duration = doc.meeting.duration_seconds();
            if duration > 0. {
                self.playhead = (seconds / duration).clamp(0., 1.) as f32;
            }
        }
        self.reveal_focus();
        cx.notify();
    }

    /// Full-text matches for the list filter, 160 ms after typing stops.
    fn search_content(&mut self, cx: &mut Context<Self>) {
        let query = self.query.clone();
        if query.is_empty() {
            self.content_matches.clear();
            self.content_generation += 1;
            self.content_task = None;
            return;
        }
        let library = self.data.read(cx).library.clone();
        self.content_task = Some(cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(160))
                .await;
            let ids = cx
                .background_spawn(async move {
                    library.matching_meeting_ids(&query).unwrap_or_default()
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.content_matches = ids.into_iter().collect();
                this.content_generation += 1;
                cx.notify();
            });
        }));
    }

    // ---------------------------------------------------------------- notes

    fn load_notes_editor(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(doc) = self.doc.clone() else { return };
        let live = self.is_live_selected(cx);
        let editor = if live {
            &mut self.live_notes
        } else {
            &mut self.notes
        };
        if editor.meeting == Some(doc.meeting.id) {
            return;
        }
        editor.meeting = Some(doc.meeting.id);
        editor.saved = doc.notes.clone();
        editor.status = NotesStatus::Saved;
        editor.save_task = None;
        editor.loading = true;
        let text = doc.notes.clone();
        editor
            .input
            .update(cx, |input, cx| input.set_value(text, window, cx));
        let editor = if live {
            &mut self.live_notes
        } else {
            &mut self.notes
        };
        editor.loading = false;
    }

    fn schedule_notes_save(&mut self, live: bool, cx: &mut Context<Self>) {
        let editor = if live {
            &mut self.live_notes
        } else {
            &mut self.notes
        };
        if editor.loading {
            return;
        }
        let text = editor.input.read(cx).value().to_string();
        if text == editor.saved {
            editor.status = NotesStatus::Saved;
            editor.save_task = None;
            cx.notify();
            return;
        }
        editor.status = NotesStatus::Saving;
        let delay = if live { 600 } else { 400 };
        editor.save_task = Some(cx.spawn(async move |this, cx| {
            cx.background_executor()
                .timer(Duration::from_millis(delay))
                .await;
            let _ = this.update(cx, |this, cx| this.save_notes(live, cx));
        }));
        cx.notify();
    }

    fn save_notes(&mut self, live: bool, cx: &mut Context<Self>) {
        let editor = if live {
            &mut self.live_notes
        } else {
            &mut self.notes
        };
        let Some(meeting_id) = editor.meeting else {
            return;
        };
        let text = editor.input.read(cx).value().to_string();
        let data = self.data.read(cx);
        let meeting = data
            .recording
            .meeting()
            .filter(|m| m.id == meeting_id)
            .cloned()
            .or_else(|| data.meeting(meeting_id).cloned());
        let Some(meeting) = meeting else { return };
        let library = data.library.clone();
        let editor = if live {
            &mut self.live_notes
        } else {
            &mut self.notes
        };
        editor.save_task = Some(cx.spawn(async move |this, cx| {
            let saved_text = text.clone();
            let result = cx
                .background_spawn(async move { library.save_notes(&meeting, &text) })
                .await;
            let _ = this.update(cx, |this, cx| {
                let editor = if live {
                    &mut this.live_notes
                } else {
                    &mut this.notes
                };
                match result {
                    Ok(()) => {
                        editor.saved = saved_text;
                        editor.status = NotesStatus::Saved;
                    }
                    Err(err) => editor.status = NotesStatus::Failed(format!("{err:#}").into()),
                }
                cx.notify();
            });
        }));
    }

    /// Saves pending notes right away (before switching meetings).
    fn flush_notes(&mut self, cx: &mut Context<Self>) {
        for live in [false, true] {
            let editor = if live { &self.live_notes } else { &self.notes };
            if editor.status == NotesStatus::Saving {
                self.save_notes(live, cx);
            }
        }
    }

    // ----------------------------------------------------------------- find

    pub(crate) fn open_find(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.find.open = true;
        self.find.input.update(cx, |input, cx| {
            input.set_placeholder(lokalbot_i18n::tr("Search this meeting"), window, cx);
            input.focus(window, cx);
        });
        self.update_find_matches(false, cx);
        cx.notify();
    }

    pub(crate) fn close_find(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.find.open = false;
        self.find.query.clear();
        self.find.matches.clear();
        self.notes
            .input
            .update(cx, |input, cx| input.set_selection_focus(None, cx));
        self.find.input.update(cx, |input, cx| {
            input.set_value("", window, cx);
            input.set_placeholder(lokalbot_i18n::tr("Find in transcript"), window, cx);
        });
        cx.notify();
    }

    fn update_find_matches(&mut self, reveal: bool, cx: &mut Context<Self>) {
        self.find.matches.clear();
        self.find.current = 0;
        if let Some(doc) = self.doc.clone()
            && !self.find.query.trim().is_empty()
        {
            let stage = self
                .data
                .read(cx)
                .processing
                .get(&doc.meeting.id)
                .map(detail::stage_label);
            let notes = self.notes.input.read(cx).value().to_string();
            let notes = if self.notes.meeting == Some(doc.meeting.id) {
                notes
            } else {
                doc.notes.clone()
            };
            let processing = self.data.read(cx).is_processing(doc.meeting.id);
            let sources = page_search::sources(&doc, stage, processing, &notes, self.find.open);
            self.find.matches = page_search::matches(&self.find.query, &sources);
        }
        if reveal {
            self.reveal_find_match(cx);
        }
        cx.notify();
    }

    /// Brings the current match into view: its tab, its row in a transcript,
    /// and its words in the notes. On the overview, its text marks itself and
    /// scrolls when it paints.
    fn reveal_find_match(&mut self, cx: &mut Context<Self>) {
        use page_search::Location;
        let Some(found) = self.find.matches.get(self.find.current).cloned() else {
            return;
        };
        let location = &found.location;
        self.tab = location.tab();
        if location.needs_full_notes() {
            self.full_notes_expanded = true;
        }
        self.find.reveal.set(location.scrolls_overview());
        if let Some(row) = location.transcript_row() {
            self.transcript_state.scroll_to_reveal_item(row + 1);
        } else if self.tab == MeetingTab::Transcript {
            self.transcript_state.scroll_to_reveal_item(0);
        } else if *location == Location::Notes {
            // Native selection lands Find in the editable notes
            // (`SearchableNotesEditor`). Focus stays in the Find field, and the
            // selection shows while it does.
            let find_field = self.find.input.read(cx).focus_handle(cx);
            self.notes.input.update(cx, |input, cx| {
                input.set_selection_focus(Some(find_field), cx);
                input.set_selected_range(found.range.clone(), cx);
            });
        }
    }

    pub(crate) fn move_find(&mut self, by: isize, cx: &mut Context<Self>) {
        let count = self.find.matches.len();
        if count == 0 {
            return;
        }
        self.find.current = (self.find.current as isize + by).rem_euclid(count as isize) as usize;
        self.reveal_find_match(cx);
        cx.notify();
    }

    /// `exportAudio`: the tracks mixed into one file. Audio stays on this
    /// computer until the person saves it somewhere else.
    fn export_audio(&mut self, cx: &mut Context<Self>) {
        let Some(doc) = self.doc.clone() else { return };
        if self.exporting_audio || !doc.has_audio {
            return;
        }
        let name = format!(
            "{}-audio.wav",
            lokalbot_core::ids::slugify(&doc.meeting.display_title())
        );
        let receiver = cx.prompt_for_new_path(&directories_home(), Some(&name));
        let data = self.data.clone();
        let (mic, system) = (doc.mic.clone(), doc.system.clone());
        cx.spawn(async move |this, cx| {
            let Ok(Ok(Some(path))) = receiver.await else {
                return;
            };
            let _ = this.update(cx, |this, cx| {
                this.exporting_audio = true;
                cx.notify();
            });
            let result = cx
                .background_spawn(async move {
                    lokalbot_audio::export_mixed(mic.as_deref(), system.as_deref(), &path)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.exporting_audio = false;
                cx.notify();
            });
            data.update(cx, |data, cx| match result {
                Ok(_) => data.show_message(lokalbot_i18n::tr("Audio exported."), cx),
                Err(err) => data.show_error(
                    lokalbot_i18n::format(
                        "Audio export failed: {err}",
                        &[("err", err.to_string())],
                    ),
                    cx,
                ),
            });
        })
        .detach();
    }

    // -------------------------------------------------------------- actions

    pub(crate) fn set_action_status(
        &mut self,
        action_id: String,
        status: ActionStatus,
        cx: &mut Context<Self>,
    ) {
        let Some(meeting_id) = self.doc.as_ref().map(|d| d.meeting.id) else {
            return;
        };
        self.data.update(cx, |data, cx| {
            data.set_action_status(meeting_id, action_id, status, cx)
        });
    }

    pub(crate) fn process(&mut self, transcribe: bool, summarize: bool, cx: &mut Context<Self>) {
        let Some(meeting_id) = self.selected else {
            return;
        };
        self.data.update(cx, |data, cx| {
            data.request(
                AppEvent::ProcessMeeting {
                    meeting_id,
                    transcribe,
                    summarize,
                },
                cx,
            )
        });
    }

    fn open_follow_up(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(doc) = self.doc.clone() else { return };
        follow_up::FollowUpSheet::open(self.data.clone(), doc.meeting.clone(), window, cx);
    }

    fn ask_meeting(&mut self, cx: &mut Context<Self>) {
        let Some(meeting_id) = self.selected else {
            return;
        };
        self.data.update(cx, |data, cx| {
            data.ask(
                AskRequest {
                    question: lokalbot_i18n::tr("Help me understand this meeting").into(),
                    meeting_ids: vec![meeting_id],
                    submit: false,
                    day: None,
                },
                cx,
            )
        });
    }

    fn copy_text(&self, text: String, message: &str, cx: &mut Context<Self>) {
        cx.write_to_clipboard(ClipboardItem::new_string(text));
        let message = message.to_string();
        self.data
            .update(cx, |data, cx| data.show_message(message, cx));
    }

    fn export_markdown(&mut self, cx: &mut Context<Self>) {
        let Some(doc) = self.doc.clone() else { return };
        let markdown = model::meeting_markdown(&doc);
        let name = format!(
            "{}.md",
            lokalbot_core::ids::slugify(&doc.meeting.display_title())
        );
        let directory = directories_home();
        let receiver = cx.prompt_for_new_path(&directory, Some(&name));
        let data = self.data.clone();
        cx.spawn(async move |_, cx| {
            let Ok(Ok(Some(path))) = receiver.await else {
                return;
            };
            let result = cx
                .background_spawn(async move { std::fs::write(&path, markdown) })
                .await;
            data.update(cx, |data, cx| match result {
                Ok(()) => data.show_message(lokalbot_i18n::tr("Meeting exported as Markdown."), cx),
                Err(err) => data.show_error(
                    lokalbot_i18n::format(
                        "Meeting export failed: {err}",
                        &[("err", format!("{}", err))],
                    ),
                    cx,
                ),
            });
        })
        .detach();
    }

    // ------------------------------------------------------------- live tick

    /// Re-renders the live view five times a second for the timer and meters.
    fn sync_tick(&mut self, live_visible: bool, cx: &mut Context<Self>) {
        if live_visible && self.tick.is_none() {
            self.tick = Some(cx.spawn(async move |this, cx| {
                loop {
                    cx.background_executor()
                        .timer(Duration::from_millis(200))
                        .await;
                    if this.update(cx, |_, cx| cx.notify()).is_err() {
                        break;
                    }
                }
            }));
        } else if !live_visible {
            self.tick = None;
        }
    }

    // --------------------------------------------------------------- render

    /// Where the tab switcher sits: centered over the page, but clear of the
    /// toolbar items and window controls on the right. Returns x, segment width.
    fn tabs_geometry(&self) -> Option<(Pixels, Pixels)> {
        let page = self.page_bounds.get()?;
        let width = page.size.width;
        let segment = if width < px(760.) {
            px(70.)
        } else if width < px(900.) {
            px(74.)
        } else {
            px(86.)
        };
        let tabs = segmented_tabs::width(TABS.len(), segment);
        let reserved = if width < px(900.) { px(270.) } else { px(390.) };
        let centered = page.origin.x + width / 2. - tabs / 2.;
        let x = centered
            .min(page.origin.x + width - reserved - tabs)
            .max(page.origin.x + px(120.));
        Some((x, segment))
    }

    fn toolbar_tabs(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let page = self.page_bounds.get()?;
        let (x, segment) = self.tabs_geometry()?;
        let y = page.origin.y - metric::TOOLBAR_HEIGHT
            + (metric::TOOLBAR_HEIGHT - segmented_tabs::HEIGHT) / 2.;
        let on_select = cx.listener(|this, ix: &usize, _, cx| this.set_tab(tab_at(*ix), cx));
        let tabs = segmented_tabs::segmented_tabs(
            "meeting-tabs",
            &TABS,
            tab_index(self.tab),
            segment,
            move |ix, window, cx| on_select(&ix, window, cx),
            cx,
        );
        Some(deferred(anchored().position(point(x, y)).child(tabs)).into_any_element())
    }
}

fn doc_has_journal(doc: &Option<Rc<MeetingDoc>>) -> bool {
    doc.as_ref().is_some_and(|doc| doc.identity.is_some())
}

/// A toolbar menu symbol with a small chevron, like macOS menu buttons.
fn menu_glyph(icon: Ico, chevron: bool, cx: &App) -> impl IntoElement {
    use crate::theme::LbThemeExt as _;
    let color = cx.lb().text;
    h_flex()
        .gap(px(3.))
        .items_center()
        .child(ui::icon(icon, px(16.), color))
        .when(chevron, |this| {
            this.child(ui::icon(Ico::ChevronDown, px(11.), color.opacity(0.7)))
        })
}

fn directories_home() -> std::path::PathBuf {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("."))
}

impl Page for MeetingsPage {
    /// A recording in progress keeps its own title. Every state of the saved
    /// library shares one toolbar without one: a meeting's page carries its
    /// own title, and the toolbar read it as the list's.
    fn title(&self, cx: &App) -> SharedString {
        if self.is_live_selected(cx)
            && let Some(meeting) = self.selected_meeting(cx)
        {
            return meeting.display_title().into();
        }
        SharedString::default()
    }

    fn toolbar(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        self.selected?;
        if self.is_live_selected(cx) {
            let data = self.data.clone();
            let red = crate::theme::LbThemeExt::lb(&**cx).recording_text;
            return Some(
                ui::controls::bordered_icon(
                    "live-stop",
                    Ico::CircleStop,
                    lokalbot_i18n::tr("Stop Recording"),
                )
                .text_color(red)
                .on_click(move |_, _, cx| data.update(cx, |data, cx| data.stop_recording(cx)))
                .into_any_element(),
            );
        }
        // Several meetings selected: nothing here acts on one of them.
        if self.selection.len() > 1 {
            return None;
        }
        let compact = self
            .page_bounds
            .get()
            .is_some_and(|b| b.size.width < px(900.));
        let has_summary = self.doc.as_ref().is_some_and(|d| d.has_summary());
        // `Draft follow-up…` needs outcomes that are not being rewritten right
        // now; a queued or waiting meeting keeps its current outcomes.
        let can_follow_up = self.doc.as_ref().is_some_and(|d| {
            use crate::state::ProcessingStage as Stage;
            d.outcomes.as_ref().is_some_and(|o| !o.is_empty())
                && d.partial_progress.is_none()
                && !matches!(
                    self.data.read(cx).processing.get(&d.meeting.id),
                    Some(
                        Stage::PreparingModel(_)
                            | Stage::Transcribing
                            | Stage::IdentifyingSpeakers
                            | Stage::Summarizing
                    )
                )
        });
        let has_transcript = self.doc.as_ref().is_some_and(|d| d.has_transcript());
        let has_notes = has_summary || has_transcript;
        let handoff_data = self.data.clone();
        let handoff_meeting = self.doc.as_ref().map(|d| d.meeting.clone());
        let busy = self
            .doc
            .as_ref()
            .is_some_and(|d| self.data.read(cx).is_processing(d.meeting.id));
        let is_merged = self
            .doc
            .as_ref()
            .is_some_and(|d| d.meeting.is_merged_meeting());
        let has_audio = self.doc.as_ref().is_some_and(|d| d.has_audio);
        let exporting_audio = self.exporting_audio;
        let back = self.data.read(cx).evidence_return;
        let spoken = self.spoken_menu_items(cx);
        let page = cx.entity().downgrade();
        let share_page = page.clone();
        let more_page = page;
        let toolbar = h_flex()
            .gap_1()
            .items_center()
            .when_some(back, |this, back| {
                let data = self.data.clone();
                this.child(
                    Button::new("meeting-evidence-back")
                        .ghost()
                        .icon(Icon::new(Ico::ChevronLeft))
                        .label(if back.section == crate::state::Section::Actions {
                            lokalbot_i18n::tr("Back to Actions")
                        } else {
                            lokalbot_i18n::tr("Back")
                        })
                        .on_click(move |_, _, cx| {
                            data.update(cx, |data, cx| data.return_from_evidence(cx));
                        }),
                )
            })
            .children(self.toolbar_tabs(cx))
            .child(if compact {
                Button::new("meeting-ask")
                    .ghost()
                    .icon(Icon::new(Ico::Search))
                    .tooltip(lokalbot_i18n::tr("Ask about this meeting"))
                    .on_click(cx.listener(|this, _, _, cx| this.ask_meeting(cx)))
            } else {
                ui::controls::bordered_icon(
                    "meeting-ask",
                    Ico::Search,
                    lokalbot_i18n::tr("Ask about this meeting"),
                )
                .on_click(cx.listener(|this, _, _, cx| this.ask_meeting(cx)))
            })
            // Everything that copies or exports the meeting.
            .child(
                Button::new("meeting-share")
                    .ghost()
                    .child(menu_glyph(Ico::Share, !compact, cx))
                    .tooltip(lokalbot_i18n::tr("Share"))
                    .dropdown_menu(move |menu, _, _| {
                        let p = share_page.clone();
                        let item = |label: &'static str,
                                    f: fn(&mut MeetingsPage, &mut Context<MeetingsPage>)| {
                            let p = p.clone();
                            PopupMenuItem::new(label).on_click(move |_, _, cx| {
                                let _ = p.update(cx, f);
                            })
                        };
                        let menu = menu
                            .item(item(lokalbot_i18n::tr("Copy as Markdown"), |this, cx| {
                                if let Some(doc) = this.doc.clone() {
                                    this.copy_text(
                                        model::meeting_markdown(&doc),
                                        lokalbot_i18n::tr("Meeting copied as Markdown."),
                                        cx,
                                    );
                                }
                            }))
                            .item(item(
                                lokalbot_i18n::tr("Export as Markdown…"),
                                |this, cx| this.export_markdown(cx),
                            ))
                            .separator()
                            .item(
                                item(lokalbot_i18n::tr("Copy summary"), |this, cx| {
                                    if let Some(summary) =
                                        this.doc.as_ref().and_then(|d| d.summary.clone())
                                    {
                                        this.copy_text(
                                            summary,
                                            lokalbot_i18n::tr("Summary copied."),
                                            cx,
                                        );
                                    }
                                })
                                .disabled(!has_summary),
                            )
                            .item(
                                item(lokalbot_i18n::tr("Copy transcript"), |this, cx| {
                                    if let Some(doc) = this.doc.clone() {
                                        this.copy_text(
                                            model::transcript_text(&doc),
                                            lokalbot_i18n::tr("Transcript copied."),
                                            cx,
                                        );
                                    }
                                })
                                .disabled(!has_transcript),
                            )
                            .separator()
                            .item(
                                item(
                                    if exporting_audio {
                                        lokalbot_i18n::tr("Exporting audio…")
                                    } else {
                                        lokalbot_i18n::tr("Export audio…")
                                    },
                                    |this, cx| this.export_audio(cx),
                                )
                                .disabled(exporting_audio || !has_audio),
                            );
                        spoken.add_export(menu, p.clone()).separator().item(item(
                            lokalbot_i18n::tr("Copy meeting path"),
                            |this, cx| {
                                if let Some(path) =
                                    this.doc.as_ref().map(|d| d.folder.display().to_string())
                                {
                                    this.copy_text(
                                        path,
                                        lokalbot_i18n::tr("Meeting path copied."),
                                        cx,
                                    );
                                }
                            },
                        ))
                    }),
            )
            .child(
                Button::new("meeting-more")
                    .ghost()
                    .child(menu_glyph(Ico::Ellipsis, !compact, cx))
                    .tooltip(lokalbot_i18n::tr("More meeting actions"))
                    .dropdown_menu(move |menu, window, cx| {
                        let p = more_page.clone();
                        let item = |label: &'static str,
                                    f: fn(
                            &mut MeetingsPage,
                            &mut Window,
                            &mut Context<MeetingsPage>,
                        )| {
                            let p = p.clone();
                            PopupMenuItem::new(label).on_click(move |_, window, cx| {
                                let _ = p.update(cx, |this, cx| f(this, window, cx));
                            })
                        };
                        let mut menu = menu.item(
                            item(
                                lokalbot_i18n::tr("Draft follow-up…"),
                                |this, window, cx| this.open_follow_up(window, cx),
                            )
                            .disabled(!can_follow_up),
                        );
                        let targets = crate::agent_handoff::for_meetings();
                        if !targets.is_empty() {
                            let data = handoff_data.clone();
                            let meeting = handoff_meeting.clone();
                            menu = menu.submenu(
                                lokalbot_i18n::tr("Open in"),
                                window,
                                cx,
                                move |sub, _, _| {
                                    let mut sub = sub;
                                    for target in &targets {
                                        let target = *target;
                                        let data = data.clone();
                                        let meeting = meeting.clone();
                                        sub = sub.item(
                                            PopupMenuItem::new(target.name())
                                                .disabled(!has_notes)
                                                .on_click(move |_, _, cx| {
                                                    if let Some(meeting) = meeting.as_ref() {
                                                        crate::agent_handoff::hand_off_meeting(
                                                            &data, meeting, target, cx,
                                                        );
                                                    }
                                                }),
                                        );
                                    }
                                    sub
                                },
                            );
                        }
                        let menu = spoken.add_read(menu.separator(), p.clone()).separator();
                        let menu = menu
                            .item(
                                item(
                                    lokalbot_i18n::tr("Edit start and end…"),
                                    |this, window, cx| {
                                        if let Some(doc) = this.doc.clone() {
                                            dialogs::BoundarySheet::open(
                                                this.data.clone(),
                                                doc.meeting.clone(),
                                                window,
                                                cx,
                                            );
                                        }
                                    },
                                )
                                .disabled(!has_transcript || busy),
                            )
                            .submenu(lokalbot_i18n::tr("Reprocess"), window, cx, {
                                let p = p.clone();
                                move |sub, _, _| {
                                    let run =
                                        |label: &'static str, transcribe: bool, summarize: bool| {
                                            let p = p.clone();
                                            PopupMenuItem::new(label).on_click(move |_, _, cx| {
                                                let _ = p.update(cx, |this, cx| {
                                                    this.process(transcribe, summarize, cx)
                                                });
                                            })
                                        };
                                    sub.item(run(
                                        lokalbot_i18n::tr("Transcribe & Summarize"),
                                        true,
                                        true,
                                    ))
                                    .item(run(lokalbot_i18n::tr("Transcribe only"), true, false))
                                    .item(run(
                                        lokalbot_i18n::tr("Summarize again"),
                                        false,
                                        true,
                                    ))
                                }
                            })
                            .separator()
                            .item(item(lokalbot_i18n::tr("Show in Folder"), |this, _, cx| {
                                if let Some(doc) = this.doc.as_ref() {
                                    cx.reveal_path(&doc.folder);
                                }
                            }))
                            // Linux and Windows have no Edit menu to carry
                            // Find; Ctrl+F works everywhere on the page.
                            .item(item(
                                lokalbot_i18n::tr("Find on this meeting page (Ctrl+F)"),
                                |this, window, cx| this.open_find(window, cx),
                            ));
                        menu.when(is_merged, |menu| {
                            menu.separator().item(
                                item(lokalbot_i18n::tr("Undo merge…"), |this, window, cx| {
                                    if let Some(doc) = this.doc.clone() {
                                        dialogs::confirm_undo_merge(
                                            this.data.clone(),
                                            &doc.meeting,
                                            window,
                                            cx,
                                        );
                                    }
                                })
                                .disabled(busy),
                            )
                        })
                    }),
            );
        Some(toolbar.into_any_element())
    }
}

impl Render for MeetingsPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.rebuild_entries(cx);
        self.release_screen_thumbnails(window, cx);
        let live = self.is_live_selected(cx);
        // Ctrl+F, from anywhere on the page (`canSearchSelectedMeeting`).
        if self.data.update(cx, |data, _| {
            std::mem::take(&mut data.meeting_find_requested)
        }) && !live
            && self.doc.is_some()
            && !window.has_active_dialog(cx)
        {
            self.open_find(window, cx);
        }
        let recording = self.data.read(cx).recording.is_active();
        self.sync_tick(recording, cx);
        if live {
            self.load_notes_editor(window, cx);
        }

        let bounds_cell = self.page_bounds.clone();
        let measure = canvas(
            move |bounds, window, _| {
                if bounds_cell.get() != Some(bounds) {
                    bounds_cell.set(Some(bounds));
                    window.request_animation_frame();
                }
            },
            |_, _, _, _| {},
        )
        .absolute()
        .size_full();

        h_flex().size_full().relative().child(measure).child({
            let list = self.render_list_column(window, cx).into_any_element();
            let detail = if live {
                self.render_live(window, cx)
            } else {
                self.render_detail(window, cx)
            };
            ui::split::leading(
                "LokalBot.meetings",
                crate::theme::metric::CONTENT_COLUMN_WIDTH,
                ui::split::LIST_RANGE,
                list,
                div().size_full().child(detail),
                &self.data,
                cx,
            )
        })
    }
}

/// Speaker color by palette index.
pub(crate) fn speaker_color(index: usize, cx: &App) -> gpui_kit::Hsla {
    use crate::theme::LbThemeExt as _;
    cx.lb().speaker(index)
}

pub(crate) fn status_text(status: &NotesStatus) -> SharedString {
    match status {
        NotesStatus::Saved => lokalbot_i18n::tr("Saved on this PC").into(),
        NotesStatus::Saving => lokalbot_i18n::tr("Saving…").into(),
        NotesStatus::Failed(_) => lokalbot_i18n::tr("Not saved").into(),
    }
}
