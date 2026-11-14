//! People (`PeopleWorkspaceView.swift`, `PersonPageView.swift`): everyone
//! from your meetings, listed by time only (Coming up, Last 2 weeks,
//! Earlier), and each person's page. The page leads with the next calendar
//! meeting together and Prepare, then what is open between you, what the
//! last meeting said and what you decided together; projects, meetings and
//! other names sit in a side column. People stays apart from voice profiles.

mod detail;
mod list;
pub(crate) mod model;
mod sheets;

use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::time::Duration;

use chrono::{DateTime, NaiveDate, Utc};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenu, PopupMenuItem};
use gpui_kit::component::{Disableable as _, Icon};
use gpui_kit::{
    AnyElement, App, AppContext as _, Bounds, Context, Entity, IntoElement, ParentElement as _,
    Pixels, Render, ScrollHandle, SharedString, Styled as _, Subscription, Task, Window, canvas,
    div, px,
};
use lokalbot_core::action_completion::CompletionHint;
use lokalbot_core::people::upcoming::{self as upcoming, PersonUpcomingMeeting};
use lokalbot_core::{HiddenPerson, Meeting, PeopleCuration, PersonMerge, PersonProfile};
use lokalbot_engine::CalendarStatus;
use uuid::Uuid;

use self::model::ListContent;
use crate::i18n::h_flex;
use crate::pages::Page;
use crate::state::{AppData, AskRequest, MeetingTab};
use crate::theme::{LbThemeExt as _, metric};
use crate::ui::{self, Ico};

const PROVENANCE: &str = "Built on this PC from calendar attendees, names you gave speakers, action owners, and meeting notes. Email addresses are used only to tell people apart and are never shown or shared.";

/// How often the coming week is matched again while People is open: a
/// meeting that has started or ended still has to leave "Coming up" without
/// a visit elsewhere.
const UPCOMING_REFRESH: Duration = Duration::from_secs(60);

/// What the list was last built from (`PeopleListCache.Key`).
#[derive(Clone, PartialEq)]
struct ListKey {
    generation: u64,
    query: String,
    day: NaiveDate,
    language: &'static str,
}

/// What the coming week was last matched from, so a page redraw does not
/// match it again.
#[derive(Clone, PartialEq)]
struct UpcomingKey {
    /// `PeoplePage::people_generation`.
    people: u64,
    enabled: bool,
    ready: bool,
    refreshed_at: Option<DateTime<Utc>>,
    events: usize,
    recordings: usize,
    recording_event: Option<String>,
    minute: i64,
}

pub struct PeoplePage {
    data: Entity<AppData>,
    people: Vec<PersonProfile>,
    curation: PeopleCuration,
    /// The user's own names, left out of Coming up.
    self_names: Vec<String>,
    loaded: bool,
    loaded_revision: Option<u64>,
    selected: Option<String>,
    search: Entity<InputState>,
    query: String,
    rename_input: Entity<InputState>,
    /// "Looks done?" suggestions, by thread.
    hints: HashMap<String, CompletionHint>,
    /// The newest small meeting with outcomes for each person, for "Draft
    /// follow-up".
    follow_ups: HashMap<String, Meeting>,
    /// Each person's next calendar meeting in the coming week, by person ID.
    /// Empty without calendar use.
    upcoming: HashMap<String, PersonUpcomingMeeting>,
    upcoming_key: Option<UpcomingKey>,
    /// Bumped each time the people are loaded.
    people_generation: u64,
    /// Bumped whenever the people, the hidden entries or the coming week
    /// change, so the list is built again.
    generation: u64,
    list_cache: RefCell<Option<(ListKey, Rc<ListContent>)>>,
    /// The page's own state, reset when another person is chosen.
    shows_all_decisions: bool,
    shows_all_series: bool,
    expanded_series: HashSet<String>,
    list_scroll: ScrollHandle,
    detail_scroll: ScrollHandle,
    /// The whole page, for the toolbar's compact form.
    page_bounds: Rc<Cell<Option<Bounds<Pixels>>>>,
    /// The person's pane, for where the side column goes.
    detail_bounds: Rc<Cell<Option<Bounds<Pixels>>>>,
    _refresh: Task<()>,
    _subscriptions: Vec<Subscription>,
}

impl PeoplePage {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let data = AppData::global(cx);
        let search = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                "Search people",
                window,
                cx,
            ))
        });
        let rename_input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder("Name", window, cx))
        });
        let subscriptions = vec![
            cx.observe(&data, |this, data, cx| {
                if this.loaded_revision != Some(data.read(cx).revision) {
                    this.reload(cx);
                }
                if data.read(cx).person_focus.is_some() {
                    this.take_focus(cx);
                }
                this.refresh_upcoming(false, cx);
            }),
            cx.subscribe_in(&search, window, |this, input, event: &InputEvent, _, cx| {
                if matches!(event, InputEvent::Change) {
                    this.query = input.read(cx).value().to_string();
                    cx.notify();
                }
            }),
        ];
        let refresh = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor().timer(UPCOMING_REFRESH).await;
                if this
                    .update(cx, |this, cx| this.refresh_upcoming(true, cx))
                    .is_err()
                {
                    break;
                }
            }
        });
        let mut page = Self {
            data,
            people: Vec::new(),
            curation: PeopleCuration::default(),
            self_names: Vec::new(),
            loaded: false,
            loaded_revision: None,
            selected: None,
            search,
            query: String::new(),
            rename_input,
            hints: HashMap::new(),
            follow_ups: HashMap::new(),
            upcoming: HashMap::new(),
            upcoming_key: None,
            people_generation: 0,
            generation: 0,
            list_cache: RefCell::new(None),
            shows_all_decisions: false,
            shows_all_series: false,
            expanded_series: HashSet::new(),
            list_scroll: ScrollHandle::new(),
            detail_scroll: ScrollHandle::new(),
            page_bounds: Rc::new(Cell::new(None)),
            detail_bounds: Rc::new(Cell::new(None)),
            _refresh: refresh,
            _subscriptions: subscriptions,
        };
        page.reload(cx);
        page
    }

    fn reload(&mut self, cx: &mut Context<Self>) {
        crate::agent_handoff::refresh_in_background();
        let library = self.data.read(cx).library.clone();
        let suggest_done = crate::ui::action_row::suggests_completion(&self.data.read(cx).settings);
        let meetings = self.data.read(cx).meetings.clone();
        self.loaded_revision = Some(self.data.read(cx).revision);
        cx.spawn(async move |this, cx| {
            let loaded = cx
                .background_spawn(async move {
                    let people = library.people();
                    let (hints, follow_ups) = match &people {
                        Ok(people) => (
                            hints_for(&library, people, suggest_done),
                            follow_up_meetings(&library, people, &meetings),
                        ),
                        Err(_) => Default::default(),
                    };
                    let self_names = library.self_names();
                    (
                        people,
                        library.people_curation(),
                        hints,
                        follow_ups,
                        self_names,
                    )
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                match loaded {
                    (Ok(people), curation, hints, follow_ups, self_names) => {
                        this.people = people;
                        this.curation = curation.unwrap_or_default();
                        this.hints = hints;
                        this.follow_ups = follow_ups;
                        this.self_names = self_names;
                        this.people_generation += 1;
                        this.generation += 1;
                    }
                    (Err(err), ..) => log::warn!("loading people failed: {err:#}"),
                }
                this.loaded = true;
                this.refresh_upcoming(true, cx);
                cx.notify();
            });
        })
        .detach();
    }

    /// Reads the coming week only while calendar use is on and the calendar
    /// has been read, and matches its meetings to people by the directory's
    /// keys (`refreshUpcoming`). Nothing is stored.
    fn refresh_upcoming(&mut self, force: bool, cx: &mut Context<Self>) {
        let now = Utc::now();
        let data = self.data.read(cx);
        let key = UpcomingKey {
            people: self.people_generation,
            enabled: data.settings.calendar_detection_enabled,
            ready: data.calendar.status == CalendarStatus::Ready,
            refreshed_at: data.calendar.refreshed_at,
            events: data.calendar.events.len(),
            recordings: data.meetings.len(),
            recording_event: data
                .recording
                .meeting()
                .and_then(|m| m.calendar_event_id.clone()),
            minute: now.timestamp() / 60,
        };
        if !force && self.upcoming_key.as_ref() == Some(&key) {
            return;
        }
        let events = upcoming::readable_events(key.enabled, key.ready, &data.calendar.events);
        // A recording that stores its calendar event stands in for it.
        let recorded: HashSet<String> = data
            .meetings
            .iter()
            .filter_map(|m| m.calendar_event_id.clone())
            .chain(key.recording_event.clone())
            .collect();
        let matched = upcoming::match_people(
            events.as_deref(),
            &self.people,
            &recorded,
            &self.self_names,
            now,
        );
        self.upcoming_key = Some(key);
        if matched != self.upcoming {
            self.upcoming = matched;
            self.generation += 1;
            cx.notify();
        }
    }

    fn save_curation(&mut self, curation: PeopleCuration, cx: &mut Context<Self>) {
        self.curation = curation.clone();
        self.generation += 1;
        let library = self.data.read(cx).library.clone();
        let data = self.data.clone();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_spawn(async move { library.save_people_curation(&curation) })
                .await;
            if let Err(err) = result {
                data.update(cx, |data, cx| {
                    data.show_error(
                        lokalbot_i18n::format(
                            "Could not save People changes: {err}",
                            &[("err", format!("{:#}", err))],
                        ),
                        cx,
                    )
                });
            }
            let _ = this.update(cx, |this, cx| this.reload(cx));
        })
        .detach();
        cx.notify();
    }

    /// `PeopleStore.rename`: an empty name goes back to the name from meetings.
    fn rename(
        &mut self,
        person_id: &str,
        member_ids: &[String],
        name: &str,
        cx: &mut Context<Self>,
    ) {
        let cleaned = name.split_whitespace().collect::<Vec<_>>().join(" ");
        let mut curation = self.curation.clone();
        for id in member_ids.iter().map(String::as_str).chain([person_id]) {
            curation.names.remove(id);
        }
        if !lokalbot_core::people::normalized(&cleaned).is_empty() {
            curation.names.insert(person_id.to_string(), cleaned);
        }
        self.save_curation(curation, cx);
    }

    /// The name the person chose for someone, if any (`PeopleStore.chosenName`).
    fn chosen_name(&self, person: &PersonProfile) -> Option<&String> {
        std::iter::once(&person.id)
            .chain(person.member_ids.iter())
            .find_map(|id| self.curation.names.get(id))
    }

    /// `PeopleStore.merge`: the target keeps its name, and the selection
    /// follows the person the source joined.
    fn merge(&mut self, source: &PersonProfile, target: &PersonProfile, cx: &mut Context<Self>) {
        let mut curation = self.curation.clone();
        if curation.merge(source, target) {
            self.select(Some(target.id.clone()));
            self.save_curation(curation, cx);
        }
    }

    fn separate(&mut self, merge: &PersonMerge, cx: &mut Context<Self>) {
        let mut curation = self.curation.clone();
        curation.merges.retain(|m| m != merge);
        self.save_curation(curation, cx);
    }

    fn hide(&mut self, person: &PersonProfile, cx: &mut Context<Self>) {
        if self.curation.hidden.iter().any(|h| h.id == person.id) {
            return;
        }
        let mut curation = self.curation.clone();
        curation.hidden.push(HiddenPerson {
            id: person.id.clone(),
            name: person.name.clone(),
        });
        if self.selected.as_deref() == Some(person.id.as_str()) {
            self.select(None);
        }
        self.save_curation(curation, cx);
    }

    fn restore_hidden(&mut self, cx: &mut Context<Self>) {
        let mut curation = self.curation.clone();
        curation.hidden.clear();
        self.save_curation(curation, cx);
    }

    /// Chooses a person; their page starts at the top with its lists folded.
    fn select(&mut self, id: Option<String>) {
        if self.selected != id {
            self.shows_all_decisions = false;
            self.shows_all_series = false;
            self.expanded_series.clear();
        }
        self.selected = id;
        self.detail_scroll
            .set_offset(gpui_kit::point(px(0.), px(0.)));
    }

    /// Selects a person another page asked to show; they may sit far down
    /// the list.
    fn take_focus(&mut self, cx: &mut Context<Self>) {
        if let Some(id) = self.data.update(cx, |data, _| data.person_focus.take()) {
            let shown = self
                .people
                .iter()
                .find(|p| p.id == id || p.member_ids.contains(&id))
                .map(|p| p.id.clone());
            if let Some(index) = shown.and_then(|id| self.list_content().child_index(&id)) {
                self.list_scroll.scroll_to_item(index);
            }
            self.select(Some(id));
            cx.notify();
        }
    }

    fn hidden_ids(&self) -> HashSet<String> {
        self.curation.hidden.iter().map(|h| h.id.clone()).collect()
    }

    /// The list as drawn, built again only when what it shows changed
    /// (`PeopleListCache`).
    fn list_content(&self) -> Rc<ListContent> {
        let now = Utc::now();
        let key = ListKey {
            generation: self.generation,
            query: self.query.clone(),
            day: model::local_day(now),
            language: lokalbot_i18n::current().code,
        };
        if let Some((cached_key, content)) = self.list_cache.borrow().as_ref()
            && *cached_key == key
        {
            return content.clone();
        }
        let content = Rc::new(ListContent::build(
            &self.people,
            &self.hidden_ids(),
            &self.upcoming,
            &self.query,
            now,
        ));
        *self.list_cache.borrow_mut() = Some((key, content.clone()));
        content
    }

    /// A merge keeps the selection: an ID folded into someone else finds the
    /// person it joined. With nothing chosen, the first row's person.
    fn selected_person(&self) -> Option<&PersonProfile> {
        let hidden = self.hidden_ids();
        let visible = |p: &&PersonProfile| !hidden.contains(&p.id);
        match &self.selected {
            Some(id) => self
                .people
                .iter()
                .filter(visible)
                .find(|p| &p.id == id || p.member_ids.contains(id)),
            None => {
                let content = self.list_content();
                let first = content.person_ids().next()?.to_string();
                self.people.iter().find(|p| p.id == first)
            }
        }
    }

    fn open_meeting(&self, id: Uuid, at: Option<f64>, cx: &mut App) {
        let tab = if at.is_some() {
            MeetingTab::Transcript
        } else {
            MeetingTab::Summary
        };
        self.data
            .update(cx, |data, cx| data.open_meeting(id, tab, at, cx));
    }

    fn compact_toolbar(&self) -> bool {
        self.page_bounds
            .get()
            .is_some_and(|b| b.size.width < px(model::COMPACT_TOOLBAR_WIDTH))
    }

    /// Rename, merge, separate and hide, shared by a row's context menu and
    /// the page's More menu (`PersonMenuItems`).
    fn person_menu_items(
        page: &Entity<Self>,
        merges: Vec<PersonMerge>,
        person: PersonProfile,
        menu: PopupMenu,
        window: &mut Window,
        cx: &mut Context<PopupMenu>,
    ) -> PopupMenu {
        let rename_page = page.clone();
        let merge_page = page.clone();
        let hide_page = page.clone();
        let rename_person = person.clone();
        let merge_person = person.clone();
        let hide_person = person;
        let mut menu = menu
            .item(PopupMenuItem::new(lokalbot_i18n::tr("Rename…")).on_click(
                move |_, window, cx| {
                    let person = rename_person.clone();
                    rename_page.update(cx, |page, cx| page.open_rename(&person, window, cx));
                },
            ))
            .item(
                PopupMenuItem::new(lokalbot_i18n::tr("Merge into…")).on_click(
                    move |_, window, cx| {
                        let person = merge_person.clone();
                        merge_page.update(cx, |page, cx| page.open_merge(&person, window, cx));
                    },
                ),
            );
        if !merges.is_empty() {
            let separate_page = page.clone();
            menu = menu.submenu(
                lokalbot_i18n::tr("Separate"),
                window,
                cx,
                move |submenu, _, _| {
                    let mut submenu = submenu;
                    for merge in merges.clone() {
                        let page = separate_page.clone();
                        let label = merge.source_name.clone();
                        submenu =
                            submenu.item(PopupMenuItem::new(label).on_click(move |_, _, cx| {
                                page.update(cx, |page, cx| page.separate(&merge, cx))
                            }));
                    }
                    submenu
                },
            );
        }
        menu.separator().item(
            PopupMenuItem::new(lokalbot_i18n::tr("Not a person")).on_click(move |_, _, cx| {
                let person = hide_person.clone();
                hide_page.update(cx, |page, cx| page.hide(&person, cx));
            }),
        )
    }

    /// Ask about the person, words and icon while the toolbar has room and
    /// the icon alone when it does not; then the page's "…" menu: Prepare and
    /// follow-up first, then the corrections.
    fn render_toolbar(&self, person: &PersonProfile, cx: &mut Context<Self>) -> AnyElement {
        let first = model::first_name(person).to_string();
        let ask_label: SharedString =
            lokalbot_i18n::fill(lokalbot_i18n::tr("Ask about %@"), &[&first]).into();
        let ask_data = self.data.clone();
        let question = lokalbot_i18n::format(
            "What has {0} been working on lately, and what is open between us?",
            &[("0", person.name.to_string())],
        );
        let meeting_ids: Vec<Uuid> = person.meetings.iter().map(|m| m.id).collect();
        let ask = Button::new("person-ask")
            .icon(Icon::new(Ico::Search))
            .tooltip(ask_label.clone())
            .disabled(person.meetings.is_empty())
            .on_click(move |_, _, cx| {
                let request = AskRequest {
                    question: question.clone(),
                    meeting_ids: meeting_ids.clone(),
                    submit: false,
                    day: None,
                };
                ask_data.update(cx, |data, cx| data.ask(request, cx));
            });
        let ask = if self.compact_toolbar() {
            ask.ghost()
        } else {
            ask.secondary().label(ask_label)
        };

        let page = cx.entity();
        let menu_person = person.clone();
        let merges = self.curation.merges_into(person);
        let prepare_data = self.data.clone();
        let prepare_prompt = lokalbot_core::people::preparation_prompt(person);
        let follow_up = self.follow_ups.get(&person.id).cloned();
        let follow_up_data = self.data.clone();
        let more = Button::new("person-more")
            .ghost()
            .icon(Icon::new(Ico::Ellipsis))
            .tooltip(lokalbot_i18n::tr("More"))
            .dropdown_menu(move |menu, window, cx| {
                let prepare_data = prepare_data.clone();
                let prompt = prepare_prompt.clone();
                let mut menu = menu.item(
                    PopupMenuItem::new(lokalbot_i18n::tr("Prepare in Agent…")).on_click(
                        move |_, _, cx| {
                            let prompt = prompt.clone();
                            prepare_data.update(cx, |data, cx| data.open_agent(prompt, cx));
                        },
                    ),
                );
                if let Some(meeting) = follow_up.clone() {
                    let data = follow_up_data.clone();
                    let label = lokalbot_i18n::fill(
                        lokalbot_i18n::tr("Draft follow-up for %@…"),
                        &[&meeting.display_title()],
                    );
                    menu = menu.item(PopupMenuItem::new(label).on_click(move |_, window, cx| {
                        crate::pages::meetings::follow_up::FollowUpSheet::open(
                            data.clone(),
                            meeting.clone(),
                            window,
                            cx,
                        );
                    }));
                }
                Self::person_menu_items(
                    &page,
                    merges.clone(),
                    menu_person.clone(),
                    menu.separator(),
                    window,
                    cx,
                )
            });
        h_flex()
            .gap(px(4.))
            .items_center()
            .child(ask)
            .child(more)
            .into_any_element()
    }
}

/// "Looks done?" for each person's open work of yours, only with consent.
fn hints_for(
    library: &lokalbot_core::Library,
    people: &[PersonProfile],
    suggest_done: bool,
) -> HashMap<String, CompletionHint> {
    if !suggest_done {
        return HashMap::new();
    }
    let mut threads: Vec<lokalbot_core::ActionThread> = Vec::new();
    for thread in people.iter().flat_map(|p| p.my_actions.iter()) {
        if thread.status() == lokalbot_core::ActionStatus::Open
            && !threads.iter().any(|t| t.id == thread.id)
        {
            threads.push(thread.clone());
        }
    }
    library.action_completion_hints(&threads, Utc::now())
}

/// The newest meeting with outcomes that was small enough to be with each
/// person, rather than a team call they happened to attend (`followUpMeeting`).
fn follow_up_meetings(
    library: &lokalbot_core::Library,
    people: &[PersonProfile],
    meetings: &[Meeting],
) -> HashMap<String, Meeting> {
    let mut has_outcomes: HashMap<Uuid, bool> = HashMap::new();
    let mut result = HashMap::new();
    for person in people {
        for candidate in lokalbot_core::people::follow_up_candidates(person) {
            let Some(meeting) = meetings.iter().find(|m| m.id == candidate.id) else {
                continue;
            };
            let usable = *has_outcomes.entry(candidate.id).or_insert_with(|| {
                library
                    .outcomes(meeting)
                    .is_ok_and(|outcomes| outcomes.is_some_and(|o| !o.is_empty()))
            });
            if usable {
                result.insert(person.id.clone(), meeting.clone());
                break;
            }
        }
    }
    result
}

impl Page for PeoplePage {
    /// The selected person is the window's title, with how long you have
    /// been meeting under it.
    fn title(&self, _cx: &App) -> SharedString {
        match self.selected_person() {
            Some(person) => person.name.clone().into(),
            None => lokalbot_i18n::tr("People").into(),
        }
    }

    fn subtitle(&self, _cx: &App) -> Option<SharedString> {
        self.selected_person()
            .map(|person| model::subtitle(person, Utc::now()).into())
    }

    fn toolbar(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let person = self.selected_person()?.clone();
        Some(self.render_toolbar(&person, cx))
    }
}

impl Render for PeoplePage {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let detail = match self.selected_person().cloned() {
            Some(person) => self.render_detail(&person, cx),
            None => div()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .text_color(lb.text_secondary)
                .child(if self.loaded {
                    lokalbot_i18n::tr("Select a person.")
                } else {
                    lokalbot_i18n::tr("Loading people…")
                })
                .into_any_element(),
        };
        let list = self.render_list(cx);
        let page_cell = self.page_bounds.clone();
        let measure_page = canvas(
            move |bounds, window, _| {
                if page_cell.get() != Some(bounds) {
                    page_cell.set(Some(bounds));
                    window.request_animation_frame();
                }
            },
            |_, _, _, _| {},
        )
        .absolute()
        .size_full();
        let detail_cell = self.detail_bounds.clone();
        let measure_detail = canvas(
            move |bounds, window, _| {
                if detail_cell.get() != Some(bounds) {
                    detail_cell.set(Some(bounds));
                    window.request_animation_frame();
                }
            },
            |_, _, _, _| {},
        )
        .absolute()
        .size_full();
        div()
            .size_full()
            .relative()
            .bg(lb.window)
            .child(measure_page)
            .child(ui::split::leading(
                "LokalBot.people",
                metric::CONTENT_COLUMN_WIDTH,
                ui::split::LIST_RANGE,
                list,
                div()
                    .size_full()
                    .relative()
                    .child(measure_detail)
                    .child(detail),
                &self.data,
                cx,
            ))
    }
}
