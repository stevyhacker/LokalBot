//! Actions, a sidebar destination (`ActionsWorkspaceView.swift`): every
//! action of yours, or the threads they form, with filters, batch status
//! changes and an inspector that plays the supporting passage. Corrections
//! never alter evidence.
//!
//! Moved from Today, where it opened behind "Review Actions…", with its
//! behaviour unchanged; the redesigned list and details come later.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::Duration;

use crate::i18n::h_flex;
use chrono::{Local, NaiveDate};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::menu::{ContextMenuExt as _, DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, AppContext as _, Context, Entity, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, Render, SharedString, StatefulInteractiveElement as _, Styled as _,
    Subscription, Task, Window, div, px,
};
use lokalbot_audio::Player;
use lokalbot_core::action_completion::CompletionHint;
use lokalbot_core::{ActionReference, ActionStatus, ActionThread};
use uuid::Uuid;

use crate::pages::Page;
use crate::pages::meetings::model::{self as meeting_model, Speakers};
use crate::state::{AppData, Section};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::action_row::open_meeting;
use crate::ui::{self, Ico, action_row, segmented_tabs};

const STATUS_LABELS: [&str; 4] = ["All", "Open", "Done", "Deferred"];
const STATUSES: [ActionStatus; 3] = [
    ActionStatus::Open,
    ActionStatus::Done,
    ActionStatus::Deferred,
];

#[derive(Clone, Copy, PartialEq, Eq)]
enum Sort {
    Due,
    LatestDue,
    Recent,
}

impl Sort {
    fn label(self) -> &'static str {
        match self {
            Sort::Due => lokalbot_i18n::tr("Due, then recent"),
            Sort::LatestDue => lokalbot_i18n::tr("Latest due first"),
            Sort::Recent => lokalbot_i18n::tr("Most recent"),
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Due {
    Any,
    Overdue,
    Dated,
    Unresolved,
}

impl Due {
    fn label(self) -> &'static str {
        match self {
            Due::Any => lokalbot_i18n::tr("Any"),
            Due::Overdue => lokalbot_i18n::tr("Overdue"),
            Due::Dated => lokalbot_i18n::tr("Known date"),
            Due::Unresolved => lokalbot_i18n::tr("Resolve date"),
        }
    }

    /// `matchesDue`: overdue is open work behind today; deferred stays out.
    fn matches(self, reference: &ActionReference, today: NaiveDate) -> bool {
        match self {
            Due::Any => true,
            Due::Overdue => {
                reference.status == ActionStatus::Open
                    && reference.resolved_due_date.is_some_and(|d| d < today)
            }
            Due::Dated => reference.resolved_due_date.is_some(),
            Due::Unresolved => reference.due.is_some() && reference.resolved_due_date.is_none(),
        }
    }
}

/// Everything that narrows the list (`visibleActions`).
#[derive(Clone)]
struct Filters {
    query: String,
    status: Option<ActionStatus>,
    due: Due,
    sort: Sort,
    meeting: Option<Uuid>,
    /// The user's open actions that name a person or came from a small
    /// meeting with them, using the same rules as People.
    person_actions: Option<HashSet<String>>,
}

impl Filters {
    fn matches(&self, reference: &ActionReference, today: NaiveDate) -> bool {
        self.status.is_none_or(|s| reference.status == s)
            && self.meeting.is_none_or(|m| reference.meeting_id == m)
            && self
                .person_actions
                .as_ref()
                .is_none_or(|ids| ids.contains(&reference.id))
            && (self.query.is_empty()
                || reference.text.to_lowercase().contains(&self.query)
                || reference.meeting_title.to_lowercase().contains(&self.query)
                || reference
                    .due
                    .as_deref()
                    .is_some_and(|d| d.to_lowercase().contains(&self.query)))
            && self.due.matches(reference, today)
    }

    fn apply<'a>(
        &self,
        references: &'a [ActionReference],
        today: NaiveDate,
    ) -> Vec<&'a ActionReference> {
        let mut visible: Vec<&ActionReference> = references
            .iter()
            .filter(|r| self.matches(r, today))
            .collect();
        match self.sort {
            Sort::Recent => visible.sort_by(|a, b| {
                b.meeting_started_at
                    .cmp(&a.meeting_started_at)
                    .then(a.id.cmp(&b.id))
            }),
            Sort::Due | Sort::LatestDue => {
                let descending = self.sort == Sort::LatestDue;
                // Unknown dates stay last in either direction.
                visible.sort_by(|a, b| {
                    let order = match (a.resolved_due_date, b.resolved_due_date) {
                        (Some(x), Some(y)) if descending => y.cmp(&x),
                        (Some(x), Some(y)) => x.cmp(&y),
                        (Some(_), None) => std::cmp::Ordering::Less,
                        (None, Some(_)) => std::cmp::Ordering::Greater,
                        (None, None) => std::cmp::Ordering::Equal,
                    };
                    order
                        .then(b.meeting_started_at.cmp(&a.meeting_started_at))
                        .then(a.id.cmp(&b.id))
                })
            }
        }
        visible
    }
}

/// Threads with a visible member, in the order of their first visible member.
fn threads_matching<'a>(
    threads: &'a [ActionThread],
    visible: &[&ActionReference],
) -> Vec<&'a ActionThread> {
    let positions: HashMap<&str, usize> = visible
        .iter()
        .enumerate()
        .map(|(ix, r)| (r.id.as_str(), ix))
        .collect();
    let mut matching: Vec<(&ActionThread, usize)> = threads
        .iter()
        .filter_map(|thread| {
            let position = thread
                .references
                .iter()
                .filter_map(|r| positions.get(r.id.as_str()).copied())
                .min()?;
            Some((thread, position))
        })
        .collect();
    matching.sort_by_key(|(_, position)| *position);
    matching.into_iter().map(|(thread, _)| thread).collect()
}

/// A person the "With" filter can choose.
struct PersonChoice {
    id: String,
    name: String,
    action_ids: HashSet<String>,
}

/// What the workspace shows, loaded off the UI thread.
#[derive(Default)]
struct Loaded {
    references: Vec<ActionReference>,
    threads: Vec<ActionThread>,
    meetings: Vec<(Uuid, String)>,
    people: Vec<PersonChoice>,
    hints: HashMap<String, CompletionHint>,
}

/// The inspector's "Play Passage": one meeting's audio, opened when the
/// inspector shows it (`ActionEvidencePassages`).
struct Passages {
    meeting_id: Uuid,
    player: Option<Arc<Player>>,
    /// The citation playing.
    playing: Option<usize>,
    poll: Option<Task<()>>,
}

pub struct ActionsPage {
    data: Entity<AppData>,
    search: Entity<InputState>,
    query: String,
    status: Option<ActionStatus>,
    due: Due,
    sort: Sort,
    /// Threads rather than single actions.
    threads_mode: bool,
    meeting: Option<Uuid>,
    person: Option<String>,
    loaded: Loaded,
    is_loaded: bool,
    loaded_revision: Option<u64>,
    selection: HashSet<String>,
    selection_anchor: Option<String>,
    /// Shows a checkbox per row so several actions can be chosen without Ctrl-click.
    selecting: bool,
    failures: Vec<String>,
    passages: Option<Passages>,
    _subscriptions: Vec<Subscription>,
}

impl ActionsPage {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let data = AppData::global(cx);
        let search = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                "Search actions and meetings",
                window,
                cx,
            ))
        });
        let subscriptions = vec![
            cx.subscribe_in(&search, window, |this, input, event: &InputEvent, _, cx| {
                if let InputEvent::Change = event {
                    this.query = input.read(cx).value().trim().to_lowercase();
                    cx.notify();
                }
            }),
            cx.observe_in(&data, window, |this, data, window, cx| {
                let (section, revision) = {
                    let data = data.read(cx);
                    (data.section, data.revision)
                };
                if section != Section::Actions {
                    // Leaving the page stops a passage that is playing.
                    this.stop_passage();
                    return;
                }
                // Loads when first shown, then whenever the library changes.
                if this.loaded_revision != Some(revision) {
                    this.reload(window, cx);
                }
            }),
        ];
        Self {
            data,
            search,
            query: String::new(),
            status: Some(ActionStatus::Open),
            due: Due::Any,
            sort: Sort::Due,
            threads_mode: false,
            meeting: None,
            person: None,
            loaded: Loaded::default(),
            is_loaded: false,
            loaded_revision: None,
            selection: HashSet::new(),
            selection_anchor: None,
            selecting: false,
            failures: Vec::new(),
            passages: None,
            _subscriptions: subscriptions,
        }
    }

    pub(crate) fn reload(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        crate::agent_handoff::refresh_in_background();
        let data = self.data.read(cx);
        let library = data.library.clone();
        let suggest_done = action_row::suggests_completion(&data.settings);
        self.loaded_revision = Some(data.revision);
        cx.spawn(async move |this, cx| {
            let loaded = cx
                .background_spawn(async move {
                    let all = library.action_references(None).unwrap_or_default();
                    let mut meetings: Vec<(chrono::DateTime<chrono::Utc>, Uuid, String)> =
                        Vec::new();
                    for reference in &all {
                        if !meetings
                            .iter()
                            .any(|(_, id, _)| *id == reference.meeting_id)
                        {
                            meetings.push((
                                reference.meeting_started_at,
                                reference.meeting_id,
                                reference.meeting_title.clone(),
                            ));
                        }
                    }
                    meetings.sort_by_key(|(started, _, _)| std::cmp::Reverse(*started));
                    let threads: Vec<ActionThread> =
                        lokalbot_core::actions::cluster_threads(all.clone())
                            .into_iter()
                            .filter(|t| t.is_for_user())
                            .collect();
                    let open: Vec<ActionThread> = threads
                        .iter()
                        .filter(|t| t.status() == ActionStatus::Open)
                        .cloned()
                        .collect();
                    // Suggestions only, and only from text kept with consent.
                    let hints = if suggest_done {
                        library.action_completion_hints(&open, chrono::Utc::now())
                    } else {
                        Default::default()
                    };
                    let people = library
                        .people()
                        .unwrap_or_default()
                        .into_iter()
                        .map(|person| PersonChoice {
                            action_ids: person
                                .my_actions
                                .iter()
                                .flat_map(|t| t.references.iter().map(|r| r.id.clone()))
                                .collect(),
                            id: person.id,
                            name: person.name,
                        })
                        .collect();
                    Loaded {
                        references: all.into_iter().filter(|r| r.is_for_user).collect(),
                        threads,
                        meetings: meetings
                            .into_iter()
                            .map(|(_, id, title)| (id, title))
                            .collect(),
                        people,
                        hints,
                    }
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                let known: HashSet<&str> =
                    loaded.references.iter().map(|r| r.id.as_str()).collect();
                this.selection.retain(|id| known.contains(id.as_str()));
                this.loaded = loaded;
                this.is_loaded = true;
                cx.notify();
            });
        })
        .detach();
    }

    fn filters(&self) -> Filters {
        Filters {
            query: self.query.clone(),
            status: self.status,
            due: self.due,
            sort: self.sort,
            meeting: self.meeting,
            person_actions: self.person.as_ref().and_then(|id| {
                self.loaded
                    .people
                    .iter()
                    .find(|p| &p.id == id)
                    .map(|p| p.action_ids.clone())
            }),
        }
    }

    fn set_status(
        &mut self,
        reference: &ActionReference,
        status: ActionStatus,
        cx: &mut Context<Self>,
    ) {
        let (meeting_id, action_id) = (reference.meeting_id, reference.action_id.clone());
        self.data.update(cx, |data, cx| {
            data.set_action_status(meeting_id, action_id, status, cx)
        });
    }

    /// Changes several actions together and reports the ones that failed.
    fn set_batch_status(
        &mut self,
        references: Vec<ActionReference>,
        status: ActionStatus,
        cx: &mut Context<Self>,
    ) {
        let data = self.data.read(cx);
        let library = data.library.clone();
        let meetings: Vec<lokalbot_core::Meeting> = references
            .iter()
            .filter_map(|r| data.meeting(r.meeting_id).cloned())
            .collect();
        self.failures.clear();
        cx.spawn(async move |this, cx| {
            let failures = cx
                .background_spawn(async move {
                    let mut failures = Vec::new();
                    for reference in &references {
                        let done = meetings
                            .iter()
                            .find(|m| m.id == reference.meeting_id)
                            .is_some_and(|meeting| {
                                library
                                    .set_action_status(meeting, &reference.action_id, status)
                                    .inspect_err(|err| log::warn!("batch status: {err:#}"))
                                    .is_ok()
                            });
                        if !done {
                            failures.push(reference.text.clone());
                        }
                    }
                    failures
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.failures = failures;
                this.data
                    .update(cx, |data, cx| data.mark_library_changed(cx));
                cx.notify();
            });
        })
        .detach();
    }

    fn open_correction(
        &mut self,
        reference: &ActionReference,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(meeting) = self.data.read(cx).meeting(reference.meeting_id).cloned() else {
            return;
        };
        let resolved = reference.resolved_due_date;
        let action = meeting_model::meeting_action(reference.clone(), &Speakers::default());
        crate::pages::meetings::dialogs::CorrectionSheet::open_with_date(
            self.data.clone(),
            meeting,
            action,
            resolved,
            window,
            cx,
        );
    }

    fn click_row(
        &mut self,
        id: &str,
        modifiers: gpui_kit::Modifiers,
        visible: &[String],
        cx: &mut Context<Self>,
    ) {
        if modifiers.shift
            && let Some(anchor) = self.selection_anchor.clone()
            && let (Some(from), Some(to)) = (
                visible.iter().position(|v| *v == anchor),
                visible.iter().position(|v| v == id),
            )
        {
            let (from, to) = (from.min(to), from.max(to));
            self.selection = visible[from..=to].iter().cloned().collect();
        } else if modifiers.control || modifiers.platform || self.selecting {
            if !self.selection.remove(id) {
                self.selection.insert(id.to_string());
            }
            self.selection_anchor = Some(id.to_string());
        } else {
            self.selection = HashSet::from([id.to_string()]);
            self.selection_anchor = Some(id.to_string());
        }
        cx.notify();
    }

    fn show_details(&mut self, id: &str, cx: &mut Context<Self>) {
        self.selection = HashSet::from([id.to_string()]);
        self.selection_anchor = Some(id.to_string());
        cx.notify();
    }

    // ------------------------------------------------------------- passages

    fn stop_passage(&mut self) {
        if let Some(passages) = self.passages.take()
            && let Some(player) = passages.player
        {
            player.pause();
        }
    }

    /// Opens the inspected meeting's audio off the UI thread.
    fn sync_passages(&mut self, meeting_id: Option<Uuid>, cx: &mut Context<Self>) {
        if self.passages.as_ref().map(|p| p.meeting_id) == meeting_id {
            return;
        }
        self.stop_passage();
        let Some(meeting_id) = meeting_id else { return };
        self.passages = Some(Passages {
            meeting_id,
            player: None,
            playing: None,
            poll: None,
        });
        let data = self.data.read(cx);
        let Some(meeting) = data.meeting(meeting_id).cloned() else {
            return;
        };
        let library = data.library.clone();
        cx.spawn(async move |this, cx| {
            let opened = cx
                .background_spawn(async move {
                    let audio = library.audio(&meeting);
                    if audio.mic.is_none() && audio.system.is_none() {
                        return None;
                    }
                    Player::open(audio.mic.as_deref(), audio.system.as_deref())
                        .inspect_err(|err| log::warn!("passage audio not opened: {err:#}"))
                        .ok()
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if let Some(passages) = this.passages.as_mut()
                    && passages.meeting_id == meeting_id
                {
                    passages.player = opened.map(Arc::new);
                    cx.notify();
                }
            });
        })
        .detach();
    }

    /// "Play Passage" / "Pause" (`player.playExcerpt`).
    fn toggle_passage(&mut self, index: usize, start: f64, end: f64, cx: &mut Context<Self>) {
        let Some(passages) = self.passages.as_mut() else {
            return;
        };
        let Some(player) = passages.player.clone() else {
            return;
        };
        if passages.playing == Some(index) && player.is_playing() {
            player.pause();
            passages.playing = None;
            cx.notify();
            return;
        }
        if let Err(err) = player.play_range(start, end) {
            let message = format!("{err:#}");
            self.data
                .update(cx, |data, cx| data.show_error(message, cx));
            return;
        }
        passages.playing = Some(index);
        passages.poll = Some(cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(200))
                    .await;
                let playing = this
                    .update(cx, |this, cx| {
                        let Some(passages) = this.passages.as_mut() else {
                            return false;
                        };
                        let playing = passages.player.as_ref().is_some_and(|p| p.is_playing());
                        if !playing && passages.playing.take().is_some() {
                            cx.notify();
                        }
                        playing
                    })
                    .unwrap_or(false);
                if !playing {
                    break;
                }
            }
        }));
        cx.notify();
    }

    // --------------------------------------------------------------- render

    fn render_header(
        &self,
        visible: usize,
        thread_count: usize,
        selected: Vec<ActionReference>,
        cx: &mut Context<Self>,
    ) -> impl IntoElement {
        let lb = cx.lb().clone();
        let page = cx.entity().downgrade();
        let count = if self.threads_mode {
            lokalbot_i18n::format("{0} threads", &[("0", format!("{thread_count}"))])
        } else {
            lokalbot_i18n::format(
                "{visible} of {0}",
                &[
                    ("visible", format!("{}", visible)),
                    ("0", format!("{}", self.loaded.references.len())),
                ],
            )
        };
        h_flex()
            .px(px(20.))
            .pt(px(12.))
            .pb(px(10.))
            .gap(px(12.))
            .items_center()
            // The page's title is the toolbar's.
            .child(
                div()
                    .text_size(ty::BODY)
                    .text_color(lb.text_secondary)
                    .child(count),
            )
            .child(div().flex_1())
            .when(!self.threads_mode, |this| {
                this.when(selected.is_empty() && self.selecting, |this| {
                    this.child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                "Choose actions to change together",
                            ))),
                    )
                })
                .when(!selected.is_empty(), |this| {
                    let label: SharedString = if selected.len() == 1 {
                        lokalbot_i18n::tr("Change 1 selected action").into()
                    } else {
                        lokalbot_i18n::format(
                            "Change {count} selected actions",
                            &[("count", selected.len().to_string())],
                        )
                        .into()
                    };
                    this.child(
                        Button::new("actions-batch")
                            .outline()
                            .small()
                            .label(label)
                            .dropdown_caret(true)
                            .dropdown_menu(move |menu, _, _| {
                                let mut menu = menu;
                                for status in STATUSES {
                                    let page = page.clone();
                                    let selected = selected.clone();
                                    menu = menu.item(
                                        PopupMenuItem::new(lokalbot_i18n::tr(status.label()))
                                            .on_click(move |_, _, cx| {
                                                let selected = selected.clone();
                                                let _ = page.update(cx, |this, cx| {
                                                    this.set_batch_status(selected, status, cx)
                                                });
                                            }),
                                    );
                                }
                                menu
                            }),
                    )
                })
                .child(
                    Button::new("actions-select-mode")
                        .ghost()
                        .small()
                        .label(if self.selecting {
                            lokalbot_i18n::tr("Done")
                        } else {
                            lokalbot_i18n::tr("Select")
                        })
                        .tooltip(if self.selecting {
                            lokalbot_i18n::tr("Stop selecting actions")
                        } else {
                            lokalbot_i18n::tr(
                                "Select several actions to change their status together",
                            )
                        })
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.selecting = !this.selecting;
                            if !this.selecting {
                                this.selection.clear();
                            }
                            cx.notify();
                        })),
                )
            })
    }

    /// A small "Label: value ▾" menu.
    #[allow(clippy::too_many_arguments)]
    fn picker<T: Clone + PartialEq + 'static>(
        &self,
        id: &'static str,
        icon: Option<Ico>,
        title: &'static str,
        current: T,
        options: Vec<(SharedString, T)>,
        apply: fn(&mut Self, T),
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<T> {
        let page = cx.entity().downgrade();
        let label = options
            .iter()
            .find(|(_, value)| *value == current)
            .map(|(label, _)| label.to_string())
            .unwrap_or_default();
        let label: String = if label.chars().count() > 30 {
            label.chars().take(29).collect::<String>() + "…"
        } else {
            label
        };
        let label = if title.is_empty() {
            label
        } else {
            format!("{title}: {label}")
        };
        Button::new(id)
            .outline()
            .small()
            .when_some(icon, |this, icon| this.icon(Icon::new(icon)))
            .label(label)
            .dropdown_caret(true)
            .dropdown_menu(move |menu, _, _| {
                let mut menu = menu.scrollable(true).max_h(px(360.));
                for (label, value) in options.clone() {
                    let page = page.clone();
                    let checked = value == current;
                    menu = menu.item(PopupMenuItem::new(label).checked(checked).on_click(
                        move |_, _, cx| {
                            let value = value.clone();
                            let _ = page.update(cx, |this, cx| {
                                apply(this, value);
                                cx.notify();
                            });
                        },
                    ));
                }
                menu
            })
    }

    fn render_filters(&self, hidden_selection: usize, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let status_index = match self.status {
            None => 0,
            Some(ActionStatus::Open) => 1,
            Some(ActionStatus::Done) => 2,
            Some(ActionStatus::Deferred) => 3,
        };
        let on_status = cx.listener(|this, ix: &usize, _, cx| {
            this.status = match ix {
                1 => Some(ActionStatus::Open),
                2 => Some(ActionStatus::Done),
                3 => Some(ActionStatus::Deferred),
                _ => None,
            };
            cx.notify();
        });
        let review = self.picker(
            "actions-review",
            None,
            lokalbot_i18n::tr("Review"),
            self.threads_mode,
            vec![
                (lokalbot_i18n::tr("Actions").into(), false),
                (lokalbot_i18n::tr("Threads").into(), true),
            ],
            |this, value| this.threads_mode = value,
            cx,
        );
        let due = self.picker(
            "actions-due",
            None,
            lokalbot_i18n::tr("Due"),
            self.due,
            [Due::Any, Due::Overdue, Due::Dated, Due::Unresolved]
                .into_iter()
                .map(|d| (d.label().into(), d))
                .collect(),
            |this, value| this.due = value,
            cx,
        );
        let mut meeting_options: Vec<(SharedString, Option<Uuid>)> =
            vec![(lokalbot_i18n::tr("All meetings").into(), None)];
        meeting_options.extend(
            self.loaded
                .meetings
                .iter()
                .map(|(id, title)| (title.clone().into(), Some(*id))),
        );
        let meeting = self.picker(
            "actions-meeting",
            None,
            lokalbot_i18n::tr("Meeting"),
            self.meeting,
            meeting_options,
            |this, value| this.meeting = value,
            cx,
        );
        let mut person_options: Vec<(SharedString, Option<String>)> =
            vec![(lokalbot_i18n::tr("Anyone").into(), None)];
        person_options.extend(
            self.loaded
                .people
                .iter()
                .filter(|p| !p.action_ids.is_empty() || self.person.as_ref() == Some(&p.id))
                .map(|p| (p.name.clone().into(), Some(p.id.clone()))),
        );
        let person = self.picker(
            "actions-person",
            None,
            lokalbot_i18n::tr("With"),
            self.person.clone(),
            person_options,
            |this, value| this.person = value,
            cx,
        );
        let sort = self.picker(
            "actions-sort",
            Some(Ico::ArrowUpDown),
            "",
            self.sort,
            [Sort::Due, Sort::LatestDue, Sort::Recent]
                .into_iter()
                .map(|s| (lokalbot_i18n::tr(s.label()).into(), s))
                .collect(),
            |this, value| this.sort = value,
            cx,
        );
        v_flex()
            .px(px(20.))
            .pb(px(12.))
            .gap(px(10.))
            .child(
                h_flex().gap(px(10.)).items_center().child(review).child(
                    div()
                        .flex_1()
                        .min_w(px(200.))
                        .child(Input::new(&self.search).small().cleanable(true)),
                ),
            )
            .child(
                h_flex()
                    .gap(px(10.))
                    .items_center()
                    .flex_wrap()
                    .child(segmented_tabs::segmented_tabs(
                        "actions-status",
                        &STATUS_LABELS,
                        status_index,
                        px(74.),
                        move |ix, window, cx| on_status(&ix, window, cx),
                        cx,
                    ))
                    .child(due)
                    .child(meeting)
                    .child(person)
                    .child(sort),
            )
            .when(hidden_selection > 0 && !self.threads_mode, |this| {
                this.child(
                    h_flex()
                        .gap(px(10.))
                        .items_center()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                            "{count} selected outside these filters.",
                            &[("count", hidden_selection.to_string())],
                        )))
                        .child(
                            Button::new("actions-clear-selection")
                                .ghost()
                                .small()
                                .label(lokalbot_i18n::tr("Clear selection"))
                                .on_click(cx.listener(|this, _, _, cx| {
                                    this.selection.clear();
                                    cx.notify();
                                })),
                        ),
                )
            })
    }

    fn render_threads(&self, threads: &[&ActionThread], cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let caption = div()
            .px(px(20.))
            .pt(px(8.))
            .text_size(ty::SECONDARY)
            .text_color(lb.text_secondary)
            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                "A thread groups the same action across meetings. Changing its status updates every linked meeting.",
            )));
        if threads.is_empty() {
            return v_flex()
                .size_full()
                .child(caption)
                .child(div().flex_1().flex().items_center().justify_center().child(
                    ui::empty_state(
                        Ico::ListChecks,
                        lokalbot_i18n::tr("No matching threads"),
                        lokalbot_i18n::tr(
                            "Choose All statuses to review completed and deferred actions.",
                        ),
                        cx,
                    ),
                ))
                .into_any_element();
        }
        let separator = lb.separator;
        let count = threads.len();
        let rows = threads.iter().enumerate().map(|(ix, thread)| {
            v_flex()
                .child(action_row::thread_row(
                    format!("actions-thread-{ix}").into(),
                    thread,
                    action_row::ThreadRowOptions {
                        hint: self.loaded.hints.get(&thread.id),
                        ..Default::default()
                    },
                    &self.data,
                    cx,
                ))
                .when(ix + 1 < count, |this| {
                    this.child(div().h(px(1.)).bg(separator))
                })
        });
        v_flex()
            .size_full()
            .child(caption)
            .child(
                div()
                    .id("actions-threads")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scrollbar()
                    .child(v_flex().px(px(20.)).pb(px(20.)).children(rows)),
            )
            .into_any_element()
    }

    fn render_row(
        &self,
        ix: usize,
        reference: &ActionReference,
        visible_ids: &Arc<Vec<String>>,
        columns: Columns,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let today = Local::now().date_naive();
        let selected = self.selection.contains(reference.id.as_str());
        let done = reference.status == ActionStatus::Done;
        let toggle = {
            let page = cx.entity().downgrade();
            let reference = reference.clone();
            action_row::status_toggle(
                ("actions-toggle", ix),
                reference.status,
                false,
                move |_, cx| {
                    let next = if reference.status == ActionStatus::Done {
                        ActionStatus::Open
                    } else {
                        ActionStatus::Done
                    };
                    let _ = page.update(cx, |this, cx| this.set_status(&reference, next, cx));
                },
                cx,
            )
        };
        let owner = reference
            .owner
            .as_deref()
            .map(|o| meeting_model::display_label(o, reference.is_for_user))
            .unwrap_or_else(|| lokalbot_i18n::tr("Owner unclear").into());
        // Red once passed, amber within the week, as every action row reads.
        let due_tone = action_row::DueTone::of(
            reference.resolved_due_date,
            reference.status == ActionStatus::Open,
            today,
        );
        let due = reference
            .due
            .as_deref()
            .map(|d| lokalbot_core::due::label(d, reference.due_reference_date()))
            .unwrap_or_else(|| "—".into());
        let data = self.data.clone();
        let meeting_id = reference.meeting_id;
        let id = reference.id.clone();
        let hover = lb.hover;
        let menu = {
            let page = cx.entity().downgrade();
            let reference = reference.clone();
            let data = self.data.clone();
            action_row::options_menu(("actions-menu", ix), move |menu, _, _| {
                let mut menu = menu;
                for option in STATUSES {
                    let page = page.clone();
                    let reference = reference.clone();
                    menu = menu.item(
                        PopupMenuItem::new(lokalbot_i18n::tr(option.label()))
                            .checked(reference.status == option)
                            .on_click(move |_, _, cx| {
                                let _ = page
                                    .update(cx, |this, cx| this.set_status(&reference, option, cx));
                            }),
                    );
                }
                let correct_page = page.clone();
                let correct_ref = reference.clone();
                let details_page = page.clone();
                let details_id = reference.id.clone();
                let open_page = page.clone();
                let meeting_id = reference.meeting_id;
                let menu = menu
                    .separator()
                    .item(
                        PopupMenuItem::new(lokalbot_i18n::tr("Correct Action…")).on_click(
                            move |_, window, cx| {
                                let _ = correct_page.update(cx, |this, cx| {
                                    this.open_correction(&correct_ref, window, cx)
                                });
                            },
                        ),
                    )
                    .item(
                        PopupMenuItem::new(lokalbot_i18n::tr("Show Details")).on_click(
                            move |_, _, cx| {
                                let _ = details_page
                                    .update(cx, |this, cx| this.show_details(&details_id, cx));
                            },
                        ),
                    )
                    .item(
                        PopupMenuItem::new(lokalbot_i18n::tr("Open Meeting")).on_click(
                            move |_, _, cx| {
                                let _ = open_page.update(cx, |this, cx| {
                                    open_meeting(&this.data, meeting_id, None, cx)
                                });
                            },
                        ),
                    );
                action_row::agent_menu_items_for_reference(menu, &reference, &data)
            })
        };
        let selecting = self.selecting;
        let context_page = cx.entity().downgrade();
        let context_ref = reference.clone();
        let visible_ids = visible_ids.clone();
        h_flex()
            .id(("actions-row", ix))
            .w_full()
            .h(px(40.))
            .px(px(10.))
            .gap(px(10.))
            .items_center()
            .rounded(metric::ROW_RADIUS)
            .when(selected, |this| this.bg(lb.accent_wash))
            .when(!selected && ix % 2 == 1, |this| this.bg(lb.group_fill))
            .when(!selected, |this| this.hover(move |s| s.bg(hover)))
            .cursor_pointer()
            .when(selecting, |this| {
                this.child(ui::icon(
                    if selected {
                        Ico::SquareCheck
                    } else {
                        Ico::Square
                    },
                    px(15.),
                    if selected {
                        lb.accent_text
                    } else {
                        lb.text_secondary
                    },
                ))
            })
            .child(div().flex_none().mt(px(-1.)).child(toggle))
            .child(
                div()
                    .flex_1()
                    .min_w(px(150.))
                    .truncate()
                    .text_size(ty::BODY)
                    .text_color(if done { lb.text_secondary } else { lb.text })
                    .when(done, |this| this.line_through())
                    .child(reference.text.clone()),
            )
            .when(columns.owner, |this| {
                this.child(
                    div()
                        .w(px(90.))
                        .flex_none()
                        .truncate()
                        .text_size(ty::SECONDARY)
                        .text_color(if reference.owner.is_none() {
                            lb.attention_text
                        } else {
                            lb.text_secondary
                        })
                        .child(owner),
                )
            })
            .child(
                div()
                    .w(px(if columns.wide { 150. } else { 130. }))
                    .flex_none()
                    .truncate()
                    .text_size(ty::SECONDARY)
                    .text_color(due_tone.color(cx))
                    .child(due),
            )
            .when(columns.meeting, |this| {
                this.child(
                    div()
                        .w(px(if columns.wide { 170. } else { 140. }))
                        .flex_none()
                        .min_w_0()
                        .child(action_row::meta_link(
                            ("actions-meeting", ix),
                            reference.meeting_title.clone(),
                            None,
                            move |_, cx| open_meeting(&data, meeting_id, None, cx),
                            cx,
                        )),
                )
            })
            .when(columns.passage, |this| {
                this.child(div().w(px(92.)).flex_none().children(
                    reference.first_citation().cloned().map(|citation| {
                        let data = self.data.clone();
                        let start = citation.start;
                        action_row::evidence_pill(
                            ("actions-evidence", ix),
                            start,
                            Some(citation.excerpt.into()),
                            move |_, cx| open_meeting(&data, meeting_id, Some(start), cx),
                            cx,
                        )
                    }),
                ))
            })
            .child(menu)
            .on_click(
                cx.listener(move |this, event: &gpui_kit::ClickEvent, _, cx| {
                    this.click_row(&id, event.modifiers(), &visible_ids, cx);
                }),
            )
            .context_menu(move |menu, _, _| {
                let correct_page = context_page.clone();
                let correct_ref = context_ref.clone();
                let details_page = context_page.clone();
                let details_id = context_ref.id.clone();
                menu.item(
                    PopupMenuItem::new(lokalbot_i18n::tr("Correct Action…")).on_click(
                        move |_, window, cx| {
                            let _ = correct_page.update(cx, |this, cx| {
                                this.open_correction(&correct_ref, window, cx)
                            });
                        },
                    ),
                )
                .item(
                    PopupMenuItem::new(lokalbot_i18n::tr("Show Details")).on_click(
                        move |_, _, cx| {
                            let _ = details_page
                                .update(cx, |this, cx| this.show_details(&details_id, cx));
                        },
                    ),
                )
            })
            .into_any_element()
    }

    fn render_passage(
        &self,
        ix: usize,
        reference: &ActionReference,
        citation: &lokalbot_core::OutcomeSourceCitation,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let data = self.data.clone();
        let meeting_id = reference.meeting_id;
        let (start, end) = (citation.start, citation.end);
        let passages = self
            .passages
            .as_ref()
            .filter(|p| p.meeting_id == meeting_id);
        let can_play = passages.is_some_and(|p| p.player.is_some()) && end > start;
        let playing = passages.is_some_and(|p| {
            p.playing == Some(ix) && p.player.as_ref().is_some_and(|player| player.is_playing())
        });
        let show_page = cx.entity().downgrade();
        v_flex()
            .gap(px(8.))
            .p(px(12.))
            .rounded(metric::GROUP_RADIUS)
            .bg(lb.group_fill)
            .border_1()
            .border_color(lb.group_stroke)
            .child(
                div()
                    .text_size(ty::BODY)
                    .text_color(lb.text)
                    .child(format!("“{}”", citation.excerpt.trim())),
            )
            .child(
                h_flex()
                    .gap(px(10.))
                    .items_center()
                    .child(
                        Button::new(("inspector-play", ix))
                            .outline()
                            .small()
                            .icon(Icon::new(if playing { Ico::Pause } else { Ico::Play }))
                            .label(if playing {
                                lokalbot_i18n::tr("Pause")
                            } else {
                                lokalbot_i18n::tr("Play Passage")
                            })
                            .disabled(!can_play)
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.toggle_passage(ix, start, end, cx)
                            })),
                    )
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(lokalbot_core::time::stamp(start)),
                    ),
            )
            .child(
                ui::link(
                    ("inspector-passage", ix),
                    lokalbot_i18n::tr("Show Passage in Meeting"),
                    move |_, cx| {
                        let _ = show_page.update(cx, |this, _| {
                            if let Some(player) =
                                this.passages.as_ref().and_then(|p| p.player.as_ref())
                            {
                                player.pause();
                            }
                        });
                        open_meeting(&data, meeting_id, Some(start), cx)
                    },
                    cx,
                )
                .text_size(ty::SECONDARY),
            )
            .into_any_element()
    }

    fn render_inspector(&self, reference: &ActionReference, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let data = self.data.clone();
        let meeting_id = reference.meeting_id;
        let status = reference.status;
        let label = |text: &'static str| {
            div()
                .text_size(ty::SECONDARY)
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.text_secondary)
                .child(text)
        };
        let status_reference = reference.clone();
        let on_status = cx.listener(move |this, ix: &usize, _, cx| {
            this.set_status(&status_reference, STATUSES[*ix], cx)
        });
        let status_buttons = segmented_tabs::segmented_tabs(
            "inspector-status",
            &[
                lokalbot_i18n::tr("Open"),
                lokalbot_i18n::tr("Done"),
                lokalbot_i18n::tr("Deferred"),
            ],
            match status {
                ActionStatus::Open => 0,
                ActionStatus::Done => 1,
                ActionStatus::Deferred => 2,
            },
            px(84.),
            move |ix, window, cx| on_status(&ix, window, cx),
            cx,
        );
        let owner = reference
            .owner
            .as_deref()
            .map(|o| meeting_model::display_label(o, reference.is_for_user))
            .unwrap_or_else(|| lokalbot_i18n::tr("Not stated").into());
        let correct_ref = reference.clone();
        let passages: Vec<AnyElement> = reference
            .citations
            .iter()
            .enumerate()
            .map(|(ix, citation)| self.render_passage(ix, reference, citation, cx))
            .collect();
        v_flex()
            .id("actions-inspector")
            .size_full()
            .bg(lb.sidebar.opacity(0.5))
            .overflow_y_scrollbar()
            .child(
                v_flex()
                    .p(px(20.))
                    .gap(px(14.))
                    .child(div().text_size(ty::COLUMN_TITLE).font_weight(FontWeight::BOLD).text_color(lb.text).child(crate::ui::text::paragraph(lokalbot_i18n::tr("Action Details"))))
                    .child(div().text_size(ty::BODY).font_weight(FontWeight::SEMIBOLD).text_color(lb.text).child(reference.text.clone()))
                    .child(action_row::meta_link("inspector-meeting", reference.meeting_title.clone(), None, move |_, cx| {
                        open_meeting(&data, meeting_id, None, cx)
                    }, cx))
                    .child(v_flex().gap(px(6.)).child(label(lokalbot_i18n::tr("Status"))).child(status_buttons))
                    .child(v_flex().gap(px(4.)).child(label(lokalbot_i18n::tr("Owner"))).child(div().text_size(ty::BODY).text_color(lb.text).child(owner)))
                    .when_some(reference.due.as_deref(), |this, due| {
                        this.child(
                            v_flex().gap(px(4.)).child(label(lokalbot_i18n::tr("Due"))).child(
                                div()
                                    .text_size(ty::BODY)
                                    .text_color(lb.text)
                                    .child(lokalbot_core::due::label(due, reference.due_reference_date())),
                            ),
                        )
                    })
                    .child(
                        h_flex().child(
                            Button::new("inspector-correct")
                                .outline()
                                .small()
                                .label(lokalbot_i18n::tr("Correct Action or Resolve Date…"))
                                .on_click(cx.listener(move |this, _, window, cx| {
                                    this.open_correction(&correct_ref, window, cx)
                                })),
                        ),
                    )
                    .child(ui::divider(cx))
                    .child(label(lokalbot_i18n::tr("Original Wording")))
                    .child(div().text_size(ty::BODY).text_color(lb.text).child(reference.original_text.clone()))
                    .when_some(reference.action.due.clone(), |this, due| {
                        this.child(div().text_size(ty::SECONDARY).text_color(lb.text_secondary).child(crate::ui::text::paragraph(lokalbot_i18n::format("Original due phrase: {due}", &[("due", due.to_string())]))))
                    })
                    .children(passages)
                    .child(div().text_size(ty::SECONDARY).text_color(lb.text_secondary).child(crate::ui::text::paragraph(lokalbot_i18n::tr("Saved corrections stay separate from the original action and its supporting passage."))))
                    .when(reference.citations.is_empty(), |this| {
                        this.child(div().text_size(ty::SECONDARY).text_color(lb.text_secondary).child(crate::ui::text::paragraph(lokalbot_i18n::tr("No supporting passage was stored."))))
                    }),
            )
            .into_any_element()
    }
}

/// Which table columns fit the list width.
#[derive(Clone, Copy)]
struct Columns {
    owner: bool,
    passage: bool,
    meeting: bool,
    wide: bool,
}

impl Page for ActionsPage {
    fn title(&self, _cx: &gpui_kit::App) -> SharedString {
        lokalbot_i18n::tr("Actions").into()
    }

    /// "2 open", as the Mac's toolbar says under the title.
    fn subtitle(&self, cx: &gpui_kit::App) -> Option<SharedString> {
        let open = self.data.read(cx).open_action_count?;
        Some(
            lokalbot_i18n::tr("%lld open")
                .replace("%lld", &lokalbot_i18n::number(open))
                .into(),
        )
    }
}

impl Render for ActionsPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // Drawn only while it is the current page: the first time, load.
        if self.loaded_revision.is_none() {
            self.reload(window, cx);
        }
        let lb = cx.lb().clone();
        let today = Local::now().date_naive();
        let filters = self.filters();
        let references = std::mem::take(&mut self.loaded.references);
        let threads_all = std::mem::take(&mut self.loaded.threads);
        let visible = filters.apply(&references, today);
        let selected: Vec<ActionReference> = visible
            .iter()
            .filter(|r| self.selection.contains(r.id.as_str()))
            .map(|r| (*r).clone())
            .collect();
        let hidden_selection = self.selection.len().saturating_sub(selected.len());
        let inspected = if self.threads_mode {
            None
        } else {
            selected.first().cloned()
        };
        self.sync_passages(inspected.as_ref().map(|r| r.meeting_id), cx);
        let matching = if self.threads_mode {
            threads_matching(&threads_all, &visible)
        } else {
            Vec::new()
        };
        let list: AnyElement = if !self.is_loaded {
            div().into_any_element()
        } else if self.threads_mode {
            self.render_threads(&matching, cx)
        } else if visible.is_empty() {
            div()
                .flex_1()
                .flex()
                .items_center()
                .justify_center()
                .child(ui::empty_state(
                    Ico::ListChecks,
                    lokalbot_i18n::tr("No matching actions"),
                    lokalbot_i18n::tr(
                        "Choose All statuses to review completed and deferred actions.",
                    ),
                    cx,
                ))
                .into_any_element()
        } else {
            let list_width = f32::from(window.viewport_size().width)
                - f32::from(crate::theme::metric::SIDEBAR_WIDTH)
                - if inspected.is_some() { 320. } else { 0. };
            let columns = Columns {
                owner: list_width >= 900.,
                passage: list_width >= 820.,
                meeting: list_width >= 520.,
                wide: list_width >= 900.,
            };
            let ids: Arc<Vec<String>> = Arc::new(visible.iter().map(|r| r.id.clone()).collect());
            let rows: Vec<AnyElement> = visible
                .iter()
                .enumerate()
                .map(|(ix, r)| self.render_row(ix, r, &ids, columns, cx))
                .collect();
            div()
                .id("actions-list")
                .flex_1()
                .min_w(px(360.))
                .h_full()
                .overflow_y_scrollbar()
                .child(v_flex().px(px(10.)).pb(px(20.)).children(rows))
                .into_any_element()
        };
        let visible_count = visible.len();
        let thread_count = matching.len();
        drop(matching);
        drop(visible);
        self.loaded.threads = threads_all;
        self.loaded.references = references;
        v_flex()
            .size_full()
            .child(self.render_header(visible_count, thread_count, selected, cx))
            .child(self.render_filters(hidden_selection, cx))
            .when(!self.failures.is_empty(), |this| {
                this.child(
                    div()
                        .px(px(20.))
                        .pb(px(8.))
                        .text_size(ty::SECONDARY)
                        .text_color(lb.attention_text)
                        .child(lokalbot_i18n::format(
                            "Could not update: {0}",
                            &[("0", self.failures.join("; "))],
                        )),
                )
            })
            .child(div().h(px(1.)).bg(lb.separator))
            .child(match inspected.map(|r| self.render_inspector(&r, cx)) {
                Some(inspector) => div()
                    .flex_1()
                    .min_h_0()
                    .child(ui::split::trailing(
                        "LokalBot.actions",
                        px(320.),
                        ui::split::DETAILS_RANGE,
                        div().size_full().child(list),
                        inspector,
                        &self.data,
                        cx,
                    ))
                    .into_any_element(),
                None => div()
                    .flex_1()
                    .min_h_0()
                    .flex()
                    .child(list)
                    .into_any_element(),
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{TimeZone as _, Utc};
    use lokalbot_core::ActionItem;

    fn day(d: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 10, d).unwrap()
    }

    fn reference(
        id: &str,
        status: ActionStatus,
        due: Option<&str>,
        date: Option<NaiveDate>,
        started: u32,
    ) -> ActionReference {
        let meeting_id = Uuid::from_u128(u128::from(started));
        let action: ActionItem =
            serde_json::from_value(serde_json::json!({ "id": id, "text": id, "importance": 0 }))
                .unwrap();
        ActionReference {
            id: id.to_string(),
            meeting_id,
            meeting_title: format!("Meeting {started}"),
            meeting_started_at: Utc.with_ymd_and_hms(2026, 10, started, 9, 0, 0).unwrap(),
            action_id: id.to_string(),
            text: format!("Do {id}"),
            original_text: format!("Do {id}"),
            owner: Some("Me".to_string()),
            due: due.map(str::to_string),
            resolved_due_date: date,
            is_for_user: true,
            status,
            importance: 0,
            citations: Vec::new(),
            action,
            state_updated_at: Utc.with_ymd_and_hms(2026, 10, started, 9, 0, 0).unwrap(),
            text_was_corrected: false,
            owner_was_corrected: false,
            due_was_corrected: false,
            text_corrected_at: None,
            owner_corrected_at: None,
            due_corrected_at: None,
            is_thread_excluded: false,
        }
    }

    fn filters() -> Filters {
        Filters {
            query: String::new(),
            status: None,
            due: Due::Any,
            sort: Sort::Due,
            meeting: None,
            person_actions: None,
        }
    }

    #[test]
    fn due_filters_match_the_mac() {
        let today = day(20);
        let overdue = reference("a", ActionStatus::Open, Some("Oct 1"), Some(day(1)), 2);
        let deferred = reference("b", ActionStatus::Deferred, Some("Oct 1"), Some(day(1)), 2);
        let phrase = reference("c", ActionStatus::Open, Some("soon"), None, 2);
        let none = reference("d", ActionStatus::Open, None, None, 2);
        assert!(Due::Overdue.matches(&overdue, today));
        assert!(
            !Due::Overdue.matches(&deferred, today),
            "deferred is not overdue"
        );
        assert!(Due::Dated.matches(&deferred, today));
        assert!(!Due::Dated.matches(&phrase, today));
        assert!(Due::Unresolved.matches(&phrase, today));
        assert!(!Due::Unresolved.matches(&none, today));
        assert!(!Due::Unresolved.matches(&overdue, today));
    }

    #[test]
    fn sorting_keeps_unknown_dates_last_in_both_directions() {
        let today = day(20);
        let all = vec![
            reference("undated", ActionStatus::Open, None, None, 9),
            reference("late", ActionStatus::Open, Some("x"), Some(day(25)), 2),
            reference("soon", ActionStatus::Open, Some("x"), Some(day(21)), 2),
        ];
        let ids = |sort| {
            let mut f = filters();
            f.sort = sort;
            f.apply(&all, today)
                .iter()
                .map(|r| r.id.clone())
                .collect::<Vec<_>>()
        };
        assert_eq!(ids(Sort::Due), ["soon", "late", "undated"]);
        assert_eq!(ids(Sort::LatestDue), ["late", "soon", "undated"]);
        assert_eq!(ids(Sort::Recent), ["undated", "late", "soon"]);
    }

    #[test]
    fn meeting_person_and_search_narrow_the_list() {
        let today = day(20);
        let a = reference("a", ActionStatus::Open, None, None, 2);
        let b = reference("b", ActionStatus::Done, Some("Friday"), None, 3);
        let all = vec![a.clone(), b.clone()];
        let mut f = filters();
        f.meeting = Some(b.meeting_id);
        assert_eq!(f.apply(&all, today)[0].id, "b");
        let mut f = filters();
        f.person_actions = Some(HashSet::from(["a".to_string()]));
        assert_eq!(f.apply(&all, today)[0].id, "a");
        assert_eq!(f.apply(&all, today).len(), 1);
        let mut f = filters();
        f.query = "friday".into();
        assert_eq!(f.apply(&all, today)[0].id, "b");
        let mut f = filters();
        f.query = "meeting 2".into();
        assert_eq!(f.apply(&all, today)[0].id, "a");
        let mut f = filters();
        f.status = Some(ActionStatus::Done);
        assert_eq!(f.apply(&all, today)[0].id, "b");
    }

    #[test]
    fn threads_follow_their_first_visible_member() {
        let a = reference("a", ActionStatus::Open, None, None, 2);
        let b = reference("b", ActionStatus::Open, None, None, 3);
        let c = reference("c", ActionStatus::Open, None, None, 4);
        let threads =
            lokalbot_core::actions::cluster_threads(vec![a.clone(), b.clone(), c.clone()]);
        assert_eq!(threads.len(), 3);
        let visible = vec![&b, &a];
        let matching = threads_matching(&threads, &visible);
        assert_eq!(
            matching.len(),
            2,
            "a thread with no visible member is left out"
        );
        assert_eq!(matching[0].references[0].id, "b");
        assert_eq!(matching[1].references[0].id, "a");
    }
}
