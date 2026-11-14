//! Timeline: one day at a time (`CaptureView.swift`'s `TimelineContentView`).
//! The date is the toolbar's title and opens a calendar; arrows, Ask about
//! this day and one … menu sit at the trailing edge. The day's page fills the
//! main area as panels (Highlights, the actions from the day's meetings, the
//! work summary, decisions); a rail on the trailing side, a pane whose width
//! the divider changes and the app remembers, holds the tracked time with its
//! hour strip, the day's sessions and meetings, and All captured activity.
//! Choosing something in the rail shows its page as panels while the rail
//! stays (`TimelineRail.swift`, `TimelineDigestPage.swift`,
//! `CaptureDetailView.swift`, `ScreenMomentDetailView.swift`).

mod agent_work;
mod context;
mod day_list;
mod day_page;
mod inspect;
mod moment;
mod rail;
mod range_delete;
mod work_summary;

use std::cell::Cell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::sync::Arc;

use crate::i18n::h_flex;
use chrono::{Datelike as _, Days, Local, NaiveDate, Utc};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::calendar::{Calendar, CalendarEvent, CalendarState, Date, Matcher};
use gpui_kit::component::input::InputState;
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::popover::Popover;
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{Disableable as _, Icon, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Bounds, ClipboardItem, Context, ElementId, Entity,
    FocusHandle, FontWeight, InteractiveElement as _, IntoElement, ParentElement as _, Pixels,
    Render, RenderImage, ScrollHandle, SharedString, StatefulInteractiveElement as _, Styled as _,
    Subscription, Window, canvas, div, px,
};
use lokalbot_core::{ActionThread, DayActivity, DayDigest, Meeting, ScreenMoment};
use uuid::Uuid;

use self::context::MeetingPreview;
use self::day_list::{DayList, ListSelection, Row, RowKind};
use crate::pages::Page;
use crate::state::{AppData, AppEvent};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::action_row;
use crate::ui::section_panel::panel_column;
use crate::ui::{self, Ico};

/// The rail's divider position, kept with the other panes' (`pane_widths`).
const RAIL_PANE_KEY: &str = "timeline.rail";
/// The page's panels, widest, without its gutters (`TimelinePageMetric`).
const PAGE_MAXIMUM_WIDTH: f32 = 1100.;
const PAGE_GUTTER: f32 = 24.;

/// One day's data, loaded off the main thread.
pub(crate) struct DayModel {
    pub activity: DayActivity,
    pub digest: Option<DayDigest>,
    /// The user's actions from this day's meetings, open ones first.
    pub threads: Vec<ActionThread>,
    /// "Looks done?" suggestions, by thread.
    pub hints: HashMap<String, lokalbot_core::action_completion::CompletionHint>,
    pub meetings: Vec<Meeting>,
    pub moments: Vec<ScreenMoment>,
    /// The rail's sessions and meetings.
    pub list: DayList,
}

impl DayModel {
    /// A day whose captures have expired can still have its digest.
    fn has_day(&self) -> bool {
        !self.activity.blocks.is_empty()
            || !self.meetings.is_empty()
            || !self.moments.is_empty()
            || self.digest.is_some()
    }
}

#[derive(Clone, PartialEq)]
pub(crate) enum Selection {
    Session(String),
    Meeting(Uuid),
    /// All captured activity: every activity block and screen moment.
    RawCapture,
    /// One screen moment (`ScreenMoment::id`).
    Moment(i64),
    /// One activity block (`ActivityBlock::id`).
    Block(i64),
}

pub struct TimelinePage {
    /// "Delete screen moments…" while it is open.
    range_deletion: Option<range_delete::RangeDeletion>,
    data: Entity<AppData>,
    day: NaiveDate,
    model: Option<Rc<DayModel>>,
    load_generation: u64,
    loaded_key: Option<(u64, NaiveDate)>,
    /// What the main area shows; `None` is the day's page.
    selection: Option<Selection>,
    /// What Back returns to, nearest last ("Back to work session").
    selection_trail: Vec<Selection>,
    /// "Show all N" in a session's Screen moments, with its Find and app filter.
    moments_browsing: bool,
    moment_search: Entity<InputState>,
    moment_app: Option<String>,
    /// The day's small moment images: `None` while one is being decrypted.
    thumbnails: std::cell::RefCell<
        std::collections::HashMap<i64, Option<crate::windows::screen_image::ScreenImage>>,
    >,
    meeting_preview: Option<MeetingPreview>,
    expanded_tasks: HashSet<usize>,
    expanded_titles: HashSet<String>,
    /// An action was open while this day's page showed, so its rows stay
    /// after the last one is ticked.
    actions_had_open: bool,
    calendar: Entity<CalendarState>,
    calendar_open: bool,
    /// The page's own bounds, for the rail's opening width.
    bounds: Rc<Cell<Option<Bounds<Pixels>>>>,
    /// The hour strip's width, for its bars and labels.
    strip_width: Rc<Cell<f32>>,
    /// The rail takes Up and Down.
    rail_focus: FocusHandle,
    rail_scroll: ScrollHandle,
    /// A row to scroll into view on the next frame (a strip bar or an arrow key chose it).
    rail_reveal: Option<String>,
    /// The selected moment's decrypted image.
    moment_image: Option<moment::MomentImage>,
    /// Images no longer shown; their textures are freed on the next frame.
    released_images: Vec<Arc<RenderImage>>,
    moment_text_expanded: bool,
    moment_details_open: bool,
    moment_note: Entity<InputState>,
    /// The moment whose saved note is in `moment_note`.
    moment_note_for: Option<i64>,
    _subscriptions: Vec<Subscription>,
}

impl TimelinePage {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let data = AppData::global(cx);
        let today = Local::now().date_naive();
        let moment_search = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                "Find in this session",
                window,
                cx,
            ))
        });
        let calendar = cx.new(|cx| {
            let mut state = CalendarState::new(window, cx).disabled_matcher(Matcher::custom(
                move |date: &NaiveDate| *date > Local::now().date_naive(),
            ));
            state.set_date(today, window, cx);
            state
        });
        let subscriptions = vec![
            cx.observe(&moment_search, |_, _, cx| cx.notify()),
            cx.observe(&data, |this, _, cx| {
                this.on_data_changed(cx);
                cx.notify();
            }),
            cx.subscribe(&calendar, |this, _, event: &CalendarEvent, cx| {
                let CalendarEvent::Selected(Date::Single(Some(day))) = event else {
                    return;
                };
                this.calendar_open = false;
                this.set_day(*day, cx);
            }),
        ];
        let moment_note = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                "Why does this moment matter?",
                window,
                cx,
            ))
        });
        let mut this = Self {
            range_deletion: None,
            data,
            day: today,
            model: None,
            load_generation: 0,
            loaded_key: None,
            selection: None,
            selection_trail: Vec::new(),
            moments_browsing: false,
            moment_search,
            moment_app: None,
            thumbnails: Default::default(),
            meeting_preview: None,
            expanded_tasks: HashSet::new(),
            expanded_titles: HashSet::new(),
            actions_had_open: false,
            calendar,
            calendar_open: false,
            bounds: Rc::new(Cell::new(None)),
            strip_width: Rc::new(Cell::new(0.)),
            rail_focus: cx.focus_handle(),
            rail_scroll: ScrollHandle::new(),
            rail_reveal: None,
            moment_image: None,
            released_images: Vec::new(),
            moment_text_expanded: false,
            moment_details_open: false,
            moment_note,
            moment_note_for: None,
            _subscriptions: subscriptions,
        };
        this.on_data_changed(cx);
        this
    }

    fn on_data_changed(&mut self, cx: &mut Context<Self>) {
        let focus = self.data.update(cx, |data, _| data.timeline_focus.take());
        if let Some(focus) = focus {
            self.set_day(focus.day, cx);
            if let Some(session) = focus.session_id {
                self.select(Some(Selection::Session(session)), cx);
            }
            if let Some(moment) = focus.moment_id {
                self.selection = None;
                self.select(Some(Selection::Moment(moment)), cx);
            }
        }
        let data = self.data.read(cx);
        if !data.meetings_loaded {
            return;
        }
        let key = (data.revision, self.day);
        if self.loaded_key != Some(key) {
            self.loaded_key = Some(key);
            self.reload(cx);
        }
    }

    /// Changing the day always returns to its page.
    fn set_day(&mut self, day: NaiveDate, cx: &mut Context<Self>) {
        self.calendar_open = false;
        self.range_deletion = None;
        let day = day.min(Local::now().date_naive());
        if day == self.day {
            return;
        }
        self.day = day;
        self.selection = None;
        self.selection_trail.clear();
        self.release_thumbnails();
        self.release_moment_image();
        self.meeting_preview = None;
        self.expanded_tasks.clear();
        self.actions_had_open = false;
        self.loaded_key = None;
        self.reload(cx);
        cx.notify();
    }

    pub(crate) fn reload(&mut self, cx: &mut Context<Self>) {
        let library = self.data.read(cx).library.clone();
        let suggest_done = action_row::suggests_completion(&self.data.read(cx).settings);
        let day = self.day;
        self.load_generation += 1;
        let generation = self.load_generation;
        cx.spawn(async move |this, cx| {
            let model = cx
                .background_spawn(async move {
                    let (start, end) = lokalbot_core::time::local_day_bounds(day);
                    let threads = day_list::day_threads(
                        library.action_threads(None).unwrap_or_default(),
                        day,
                    );
                    // Suggestions only, and only from text kept with consent.
                    let hints = if suggest_done {
                        let open: Vec<ActionThread> = threads
                            .iter()
                            .filter(|t| t.status() == lokalbot_core::ActionStatus::Open)
                            .cloned()
                            .collect();
                        library.action_completion_hints(&open, Utc::now())
                    } else {
                        Default::default()
                    };
                    let activity = library.day_activity(day).unwrap_or_else(|err| {
                        log::warn!("day activity for {day}: {err:#}");
                        DayActivity::default()
                    });
                    let meetings: Vec<Meeting> = library
                        .list_own_meetings()
                        .unwrap_or_default()
                        .into_iter()
                        .filter(|m| lokalbot_core::time::local_day(m.started_at) == day)
                        .collect();
                    let list = DayList::new(
                        &activity.sessions,
                        &activity.blocks,
                        &meetings,
                        Utc::now(),
                        !activity.project_split.projects.is_empty(),
                    );
                    DayModel {
                        digest: library.day_digest(day).unwrap_or_default(),
                        threads,
                        hints,
                        meetings,
                        moments: library.screen_moments(start, end).unwrap_or_default(),
                        list,
                        activity,
                    }
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.load_generation == generation {
                    this.model = Some(Rc::new(model));
                    this.refresh_meeting_preview(cx);
                    cx.notify();
                }
            });
        })
        .detach();
    }

    /// Opens something inside the current selection, so Back returns to it.
    pub(crate) fn open_child(&mut self, child: Selection, cx: &mut Context<Self>) {
        if self.selection.as_ref() == Some(&child) {
            return;
        }
        let mut trail = std::mem::take(&mut self.selection_trail);
        trail.extend(self.selection.clone());
        self.select(Some(child), cx);
        self.selection_trail = trail;
    }

    /// Back: to what opened this selection, else to the day.
    pub(crate) fn go_back(&mut self, cx: &mut Context<Self>) {
        let mut trail = std::mem::take(&mut self.selection_trail);
        let parent = trail.pop();
        self.select(parent, cx);
        self.selection_trail = trail;
    }

    /// Shows `selection` in the main area; choosing what it shows again
    /// returns to the day's page.
    pub(crate) fn select(&mut self, selection: Option<Selection>, cx: &mut Context<Self>) {
        self.selection_trail.clear();
        self.moments_browsing = false;
        self.moment_app = None;
        let toggled_off = selection.is_some() && selection == self.selection;
        self.selection = if toggled_off { None } else { selection };
        if !matches!(self.selection, Some(Selection::Moment(_))) {
            self.release_moment_image();
        }
        self.moment_text_expanded = false;
        self.moment_details_open = false;
        self.expanded_titles.clear();
        self.meeting_preview = None;
        self.refresh_meeting_preview(cx);
        cx.notify();
    }

    /// What the rail shows as chosen: the row or All captured activity that
    /// the main area's page came from.
    fn list_selection(&self) -> ListSelection {
        let root = self.selection_trail.first().or(self.selection.as_ref());
        match root {
            None => ListSelection::Digest,
            Some(Selection::Session(id)) => ListSelection::Row(
                self.model
                    .as_ref()
                    .and_then(|m| m.list.row_showing(id).map(|row| row.id.clone()))
                    .unwrap_or_else(|| id.clone()),
            ),
            Some(Selection::Meeting(id)) => ListSelection::Row(Row::meeting_row_id(*id)),
            Some(Selection::RawCapture) => ListSelection::Raw,
            Some(Selection::Moment(_) | Selection::Block(_)) => ListSelection::None,
        }
    }

    /// Chooses a row of the rail, All captured activity or the day's page.
    /// Choosing what is already chosen returns to the day's page
    /// (`TimelineSelection.select`).
    fn choose(&mut self, target: ListSelection, cx: &mut Context<Self>) {
        if target == self.list_selection() {
            self.select(None, cx);
            return;
        }
        let selection = match &target {
            ListSelection::Digest | ListSelection::None => None,
            ListSelection::Raw => Some(Selection::RawCapture),
            ListSelection::Row(id) => {
                self.model
                    .as_ref()
                    .and_then(|m| m.list.row(id))
                    .map(|row| match &row.kind {
                        RowKind::Work(session) => Selection::Session(session.clone()),
                        RowKind::Meeting { id, .. } => Selection::Meeting(*id),
                    })
            }
        };
        // A selection opened inside another must not toggle off against it.
        self.selection = None;
        self.select(selection, cx);
    }

    /// Up and Down in the rail walk the day's page, the sessions and All
    /// captured activity.
    fn step(&mut self, by: isize, cx: &mut Context<Self>) {
        let Some(model) = self.model.clone() else {
            return;
        };
        let current = self.list_selection();
        let next = current.moved(by, &model.list);
        if next != current {
            if let ListSelection::Row(id) = &next {
                self.rail_reveal = Some(id.clone());
            }
            self.choose(next, cx);
        }
    }

    fn refresh_meeting_preview(&mut self, cx: &mut Context<Self>) {
        let Some(Selection::Meeting(id)) = self.selection.clone() else {
            return;
        };
        let Some(meeting) = self
            .model
            .as_ref()
            .and_then(|m| m.meetings.iter().find(|m| m.id == id).cloned())
        else {
            return;
        };
        let library = self.data.read(cx).library.clone();
        cx.spawn(async move |this, cx| {
            let preview = cx
                .background_spawn(async move { MeetingPreview::load(&library, meeting) })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.selection == Some(Selection::Meeting(preview.meeting.id)) {
                    this.meeting_preview = Some(preview);
                    cx.notify();
                }
            });
        })
        .detach();
    }

    /// The body's width: page and rail together.
    fn body_width(&self, window: &Window) -> f32 {
        self.bounds.get().map_or_else(
            || f32::from(window.viewport_size().width - metric::SIDEBAR_WIDTH),
            |bounds| f32::from(bounds.size.width),
        )
    }

    /// Loads the selected moment's image and note once the day has loaded.
    fn sync_selected_moment(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(Selection::Moment(id)) = self.selection else {
            return;
        };
        let Some(moment) = self
            .model
            .as_ref()
            .and_then(|model| model.moments.iter().find(|m| m.id == id).cloned())
        else {
            return;
        };
        self.load_moment_image(&moment, cx);
        if self.moment_note_for != Some(id) {
            self.moment_note_for = Some(id);
            let note = moment.saved_note.unwrap_or_default();
            self.moment_note
                .update(cx, |input, cx| input.set_value(note, window, cx));
        }
    }

    /// Ask about one work session, bounded to its moments on its day. A single
    /// moment is attached instead, as "Ask About This…" does.
    fn ask_session(
        &self,
        question: String,
        moments: Vec<lokalbot_core::ScreenMoment>,
        cx: &mut Context<Self>,
    ) {
        let day = self.day;
        self.data.update(cx, |data, cx| {
            match moments.as_slice() {
                [one] => data.ask_screen = Some(one.clone()),
                many => data.ask_screens = Some(many.iter().map(|m| m.id).collect()),
            }
            data.ask(
                crate::state::AskRequest {
                    question,
                    meeting_ids: Vec::new(),
                    submit: false,
                    day: Some(day),
                },
                cx,
            )
        });
    }

    fn ask_day(&self, question: String, meeting_ids: Vec<Uuid>, cx: &mut Context<Self>) {
        let day = self.day;
        self.data.update(cx, |data, cx| {
            data.ask(
                crate::state::AskRequest {
                    question,
                    meeting_ids,
                    submit: false,
                    day: Some(day),
                },
                cx,
            )
        });
    }

    // ---------------------------------------------------------- toolbar

    /// "Thursday, November 12", with the year for a day outside this one.
    fn day_title(&self) -> String {
        let same_year = self.day.year() == Local::now().year();
        let locale = lokalbot_i18n::date_locale();
        let pattern = lokalbot_i18n::date_pattern(if same_year {
            "%A, %B %-d"
        } else {
            "%A, %B %-d, %Y"
        });
        // Some locales' own date already names the weekday.
        let date = self.day.format_localized("%x", locale).to_string();
        let weekday = self.day.format_localized("%A", locale).to_string();
        if pattern == "%A, %x" && date.contains(&weekday) {
            return date;
        }
        self.day.format_localized(pattern, locale).to_string()
    }

    /// The … menu: write, update or rewrite the digest, copy or export it,
    /// pause or resume day memory, and reload the day (`TimelineDayMenu`).
    fn day_menu(&self, cx: &mut Context<Self>) -> AnyElement {
        let (busy, paused) = {
            let data = self.data.read(cx);
            (
                data.digest_running == Some(self.day),
                data.day_memory_paused,
            )
        };
        let digest = self.model.as_ref().and_then(|m| m.digest.as_ref());
        let title =
            day_list::digest_menu_title(busy, digest.is_some(), digest.is_some_and(|d| d.is_stale));
        let markdown = digest.map(|d| d.markdown.clone());
        let data = self.data.clone();
        let page = cx.entity().downgrade();
        let day = self.day;
        Button::new("timeline-day-menu")
            .ghost()
            .icon(Icon::new(Ico::Ellipsis))
            .dropdown_caret(true)
            .tooltip(lokalbot_i18n::tr("Digest and day memory"))
            .dropdown_menu(move |menu, _, _| {
                let write = data.clone();
                let copy = (data.clone(), markdown.clone());
                let export = (data.clone(), markdown.clone());
                let pause = data.clone();
                let reload = page.clone();
                menu.item(
                    PopupMenuItem::new(lokalbot_i18n::tr(title))
                        .disabled(busy)
                        .on_click(move |_, _, cx| {
                            write.update(cx, |data, cx| {
                                data.request(AppEvent::RegenerateDigest(day), cx)
                            })
                        }),
                )
                .item(
                    PopupMenuItem::new(lokalbot_i18n::tr("Copy digest"))
                        .disabled(markdown.is_none())
                        .on_click(move |_, _, cx| {
                            let (data, markdown) = &copy;
                            if let Some(markdown) = markdown {
                                cx.write_to_clipboard(ClipboardItem::new_string(markdown.clone()));
                                data.update(cx, |data, cx| {
                                    data.show_message(lokalbot_i18n::tr("Digest copied."), cx)
                                });
                            }
                        }),
                )
                .item(
                    PopupMenuItem::new(lokalbot_i18n::tr("Export as Markdown…"))
                        .disabled(markdown.is_none())
                        .on_click(move |_, _, cx| {
                            let (data, markdown) = &export;
                            if let Some(markdown) = markdown {
                                crate::pages::today::digest::export_markdown(
                                    data.clone(),
                                    day,
                                    markdown.clone(),
                                    cx,
                                );
                            }
                        }),
                )
                .separator()
                .item(
                    PopupMenuItem::new(lokalbot_i18n::tr(if paused {
                        "Resume day memory"
                    } else {
                        "Pause day memory"
                    }))
                    .on_click(move |_, _, cx| set_day_memory_paused(&pause, !paused, cx)),
                )
                .item(
                    PopupMenuItem::new(lokalbot_i18n::tr("Reload")).on_click(move |_, _, cx| {
                        let _ = reload.update(cx, |this, cx| this.reload(cx));
                    }),
                )
            })
            .into_any_element()
    }

    // ------------------------------------------------------------ page

    /// The column every page in the main area shares: panels that fill the
    /// width inside their gutters, up to the widest line
    /// (`TimelinePageColumn`).
    fn page_column(
        &self,
        id: impl Into<ElementId>,
        children: Vec<AnyElement>,
        cx: &App,
    ) -> AnyElement {
        div()
            .id(id)
            .size_full()
            .overflow_y_scrollbar()
            .bg(cx.lb().page)
            .child(
                h_flex()
                    .w_full()
                    .justify_center()
                    .px(px(PAGE_GUTTER))
                    .pt(px(20.))
                    .pb(px(44.))
                    .child(
                        panel_column()
                            .max_w(px(PAGE_MAXIMUM_WIDTH))
                            .children(children),
                    ),
            )
            .into_any_element()
    }

    /// "‹ Day digest": from a session, a meeting or all captured activity
    /// back to the day's page (`TimelineDigestLink`).
    fn digest_link(&self, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let back = if lokalbot_i18n::current().rtl {
            Ico::ChevronRight
        } else {
            Ico::ChevronLeft
        };
        h_flex()
            .child(
                h_flex()
                    .id("timeline-back-to-digest")
                    .gap(px(4.))
                    .items_center()
                    .cursor_pointer()
                    .text_size(ty::BODY)
                    .text_color(lb.accent_text)
                    .hover(|s| s.underline())
                    .child(ui::icon(back, px(14.), lb.accent_text))
                    .child(lokalbot_i18n::tr("Day digest"))
                    .on_click(cx.listener(|this, _, _, cx| this.select(None, cx))),
            )
            // Sits a little nearer the panel it leads to than panels sit to
            // each other.
            .mt(px(-4.))
            .mb(px(-6.))
            .into_any_element()
    }

    /// A day with nothing recorded and no digest (`TimelineEmptyDay`).
    fn render_empty_day(&self, cx: &mut Context<Self>) -> AnyElement {
        let tracking = self.data.read(cx).settings.tracking_enabled;
        div()
            .id("timeline-empty-day")
            .size_full()
            .bg(cx.lb().page)
            .flex()
            .items_center()
            .justify_center()
            .child(ui::empty_state(
                Ico::Clock,
                lokalbot_i18n::tr("Nothing recorded on this day"),
                if tracking {
                    lokalbot_i18n::tr(
                        "LokalBot keeps only what happens on this PC while day memory is on.",
                    )
                } else {
                    lokalbot_i18n::tr("Day tracking is off — enable it in Settings.")
                },
                cx,
            ))
            .into_any_element()
    }
}

/// Pauses or resumes day memory, and shows it at once, as the tray menu
/// does; the engine gets the same request either way.
fn set_day_memory_paused(data: &Entity<AppData>, paused: bool, cx: &mut App) {
    data.update(cx, |data, cx| {
        data.day_memory_paused = paused;
        cx.notify();
        data.request(AppEvent::SetDayMemoryPaused(paused), cx)
    });
}

impl Page for TimelinePage {
    fn title(&self, _cx: &App) -> SharedString {
        self.day_title().into()
    }

    /// The date, opening a calendar, with "Today" or "Yesterday" beside it;
    /// Back first when the day was opened from a search or an answer.
    fn title_control(
        &mut self,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<AnyElement> {
        let lb = cx.lb().clone();
        let today = Local::now().date_naive();
        let relative = if self.day >= today {
            Some(lokalbot_i18n::tr("Today"))
        } else if Some(self.day) == today.checked_sub_days(Days::new(1)) {
            Some(lokalbot_i18n::tr("Yesterday"))
        } else {
            None
        };
        let back = self.data.read(cx).evidence_return.is_some().then(|| {
            let data = self.data.clone();
            Button::new("timeline-evidence-back")
                .ghost()
                .icon(Icon::new(Ico::ChevronLeft))
                .label(lokalbot_i18n::tr("Back"))
                .tooltip(lokalbot_i18n::tr(
                    "Return to the source search or conversation",
                ))
                .on_click(move |_, _, cx| {
                    data.update(cx, |data, cx| data.return_from_evidence(cx));
                })
        });
        let calendar = self.calendar.clone();
        let page = cx.entity().downgrade();
        let title = self.day_title();
        let date = Popover::new("timeline-calendar")
            .open(self.calendar_open)
            .on_open_change(move |open, _, cx| {
                let _ = page.update(cx, |this, cx| {
                    this.calendar_open = *open;
                    cx.notify();
                });
            })
            .trigger(
                Button::new("timeline-day-picker")
                    .ghost()
                    .tooltip(lokalbot_i18n::tr("Choose a day"))
                    .child(
                        h_flex()
                            .gap(px(5.))
                            .items_center()
                            .child(
                                div()
                                    .text_size(ty::COLUMN_TITLE)
                                    .font_weight(FontWeight::BOLD)
                                    .text_color(lb.text)
                                    .whitespace_nowrap()
                                    .child(title),
                            )
                            .child(ui::icon(Ico::ChevronDown, px(12.), lb.text_secondary)),
                    ),
            )
            .content(move |_, _, _| {
                div().p(px(4.)).child(
                    Calendar::new(&calendar).first_day_of_week(lokalbot_i18n::first_weekday()),
                )
            });
        Some(
            h_flex()
                .gap(px(6.))
                .items_center()
                .children(back)
                .child(date)
                .when_some(relative, |this, relative| {
                    this.child(
                        div()
                            .text_size(ty::BODY)
                            .text_color(lb.text_secondary)
                            .whitespace_nowrap()
                            .child(relative),
                    )
                })
                .into_any_element(),
        )
    }

    fn toolbar(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let today = Local::now().date_naive();
        let is_today = self.day >= today;
        let (paused, screen_context) = {
            let data = self.data.read(cx);
            (
                data.day_memory_paused,
                data.settings.tracking_enabled
                    && data.settings.screen_context_capture_mode
                        != lokalbot_core::ScreenContextMode::ActivityOnly,
            )
        };
        let capture_data = self.data.clone();
        let ask_data = self.data.clone();
        let day = self.day;
        Some(
            h_flex()
                .gap_1()
                .items_center()
                .when(!is_today, |this| {
                    this.child(
                        ui::controls::bordered("timeline-today", lokalbot_i18n::tr("Today"))
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.set_day(Local::now().date_naive(), cx)
                            })),
                    )
                })
                .child(
                    ui::controls::toolbar_icon(
                        "timeline-previous",
                        Ico::ChevronLeft,
                        lokalbot_i18n::tr("Previous day"),
                    )
                    .on_click(cx.listener(|this, _, _, cx| {
                        let day = this.day - Days::new(1);
                        this.set_day(day, cx)
                    })),
                )
                .child(
                    ui::controls::toolbar_icon(
                        "timeline-next",
                        Ico::ChevronRight,
                        lokalbot_i18n::tr("Next day"),
                    )
                    .disabled(is_today)
                    .on_click(cx.listener(|this, _, _, cx| {
                        let day = this.day + Days::new(1);
                        this.set_day(day, cx)
                    })),
                )
                .child(
                    Button::new("timeline-ask-day")
                        .ghost()
                        .icon(Icon::new(Ico::Search))
                        .label(lokalbot_i18n::tr("Ask about this day"))
                        .on_click(move |_, _, cx| {
                            ask_data.update(cx, |data, cx| {
                                data.ask(
                                    crate::state::AskRequest {
                                        question: String::new(),
                                        meeting_ids: Vec::new(),
                                        submit: false,
                                        day: Some(day),
                                    },
                                    cx,
                                )
                            })
                        }),
                )
                // Port-only: a capture of the next window, while capture is on.
                .when(screen_context && !paused, |this| {
                    this.child(
                        ui::controls::toolbar_icon(
                            "timeline-capture",
                            Ico::Camera,
                            lokalbot_i18n::tr(
                                "Capture Screen Now: captures the next window you switch to",
                            ),
                        )
                        .on_click(move |_, _, cx| {
                            capture_data
                                .update(cx, |data, cx| data.request(AppEvent::CaptureScreenNow, cx))
                        }),
                    )
                })
                .child(self.day_menu(cx))
                .into_any_element(),
        )
    }
}

impl Render for TimelinePage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        for image in std::mem::take(&mut self.released_images) {
            cx.drop_image(image, Some(window));
        }
        self.sync_selected_moment(window, cx);
        let bounds = self.bounds.clone();
        let measure = canvas(
            move |b, window, _| {
                if bounds.get().map(|old| old.size) != Some(b.size) {
                    bounds.set(Some(b));
                    window.request_animation_frame();
                }
            },
            |_, _, _, _| {},
        )
        .absolute()
        .size_full();

        let body: AnyElement = match self.model.clone() {
            None => v_flex()
                .size_full()
                .items_center()
                .justify_center()
                .child(gpui_kit::component::spinner::Spinner::new())
                .into_any_element(),
            Some(model) => {
                let page = if self.selection.is_some() {
                    self.render_context(&model, window, cx)
                } else if model.has_day() {
                    self.render_day_page(&model, cx)
                } else {
                    self.render_empty_day(cx)
                };
                let rail = self.render_rail(&model, cx);
                let text_scale = self.data.read(cx).settings.text_size.scale();
                let opening = day_list::rail_width(self.body_width(window), text_scale);
                ui::split::trailing_pane(
                    RAIL_PANE_KEY,
                    px(opening),
                    day_list::RAIL_FLOOR_WIDTH..day_list::RAIL_MAXIMUM_WIDTH,
                    px(day_list::PAGE_MINIMUM_WIDTH),
                    page,
                    rail,
                    &self.data,
                    cx,
                )
                .into_any_element()
            }
        };
        div().relative().size_full().child(measure).child(body)
    }
}
