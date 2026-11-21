mod details;
mod list;
pub(super) mod model;

use std::cell::Cell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::sync::Arc;

use chrono::{Local, NaiveDate};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::calendar::CalendarState;
use gpui_kit::component::input::{InputEvent, InputState};
use gpui_kit::component::{Icon, Selectable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, AppContext as _, Bounds, Context, Entity, FocusHandle, FontWeight, IntoElement,
    ListAlignment, ListOffset, ListState, ParentElement as _, Pixels, Render, SharedString,
    Styled as _, Subscription, Task, Window, div, px,
};
use lokalbot_audio::Player;
use lokalbot_core::action_completion::CompletionHint;
use lokalbot_core::{ActionStatus, ActionThread};
use uuid::Uuid;

use crate::i18n::h_flex;
use crate::pages::Page;
use crate::pages::meetings::model::{self as meeting_model, Speakers};
use crate::state::{AppData, Section};
use crate::theme::{LbThemeExt as _, ty};
use crate::ui::{self, Ico, action_row, controls};
use model::{ListContent, ListFilter, Selection, ThreadLinks};

const DETAILS_WIDTH: f32 = 320.;

#[derive(Default)]
struct Loaded {
    threads: Vec<ActionThread>,
    hints: HashMap<String, CompletionHint>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Entry {
    Gap(f32),
    Heading(usize),
    Row(usize, usize),
}

#[derive(Clone, PartialEq, Eq)]
struct ContentKey {
    generation: u64,
    filter: ListFilter,
    kept: u64,
    today: NaiveDate,
    language: &'static str,
}

struct Passages {
    thread_id: String,
    players: HashMap<Uuid, Option<Arc<Player>>>,
    playing: Option<(String, usize)>,
    poll: Option<Task<()>>,
}

struct DuePicker {
    thread_id: String,
    calendar: Entity<CalendarState>,
    day: Option<NaiveDate>,
    _subscription: Subscription,
}

pub struct ActionsPage {
    data: Entity<AppData>,
    search: Entity<InputState>,
    filter: ListFilter,
    loaded: Loaded,
    links: Rc<ThreadLinks>,
    is_loaded: bool,
    loaded_revision: Option<u64>,
    reloads: u64,
    generation: u64,
    content: Option<(ContentKey, Rc<ListContent>)>,
    entries: Vec<Entry>,
    entry_of_row: HashMap<String, usize>,
    list_state: ListState,
    list_focus: FocusHandle,
    kept: HashSet<String>,
    kept_revision: u64,
    selection: Selection,
    current_ids: HashSet<String>,
    list_bounds: Rc<Cell<Option<Bounds<Pixels>>>>,
    details_hidden: bool,
    passages: Option<Passages>,
    due_picker: Option<DuePicker>,
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
                    let query = input.read(cx).value().to_string();
                    this.update_filter(|filter| filter.query = query, cx);
                }
            }),
            cx.observe_in(&data, window, |this, data, window, cx| {
                let (section, revision) = {
                    let data = data.read(cx);
                    (data.section, data.revision)
                };
                if section != Section::Actions {
                    this.stop_passage();
                    return;
                }
                if this.loaded_revision != Some(revision) {
                    this.reload(window, cx);
                }
            }),
        ];
        Self {
            data,
            search,
            filter: ListFilter::default(),
            loaded: Loaded::default(),
            links: Rc::default(),
            is_loaded: false,
            loaded_revision: None,
            reloads: 0,
            generation: 0,
            content: None,
            entries: Vec::new(),
            entry_of_row: HashMap::new(),
            list_state: ListState::new(0, ListAlignment::Top, px(600.)),
            list_focus: cx.focus_handle(),
            kept: HashSet::new(),
            kept_revision: 0,
            selection: Selection::default(),
            current_ids: HashSet::new(),
            list_bounds: Rc::new(Cell::new(None)),
            details_hidden: false,
            passages: None,
            due_picker: None,
            _subscriptions: subscriptions,
        }
    }

    pub(crate) fn reload(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        crate::agent_handoff::refresh_in_background();
        let data = self.data.read(cx);
        let library = data.library.clone();
        let suggest_done = ui::action_row::suggests_completion(&data.settings);
        self.loaded_revision = Some(data.revision);
        self.reloads += 1;
        let reload = self.reloads;
        cx.spawn(async move |this, cx| {
            let links_library = library.clone();
            let loaded = cx
                .background_spawn(async move {
                    let threads: Vec<ActionThread> = library
                        .action_threads(None)
                        .inspect_err(|err| log::warn!("reading actions: {err:#}"))
                        .unwrap_or_default()
                        .into_iter()
                        .filter(ActionThread::is_for_user)
                        .collect();
                    let open: Vec<ActionThread> = threads
                        .iter()
                        .filter(|t| t.status() == ActionStatus::Open)
                        .cloned()
                        .collect();
                    let hints = if suggest_done {
                        library.action_completion_hints(&open, chrono::Utc::now())
                    } else {
                        Default::default()
                    };
                    Loaded { threads, hints }
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.reloads != reload {
                    return;
                }
                this.loaded = loaded;
                this.is_loaded = true;
                this.generation += 1;
                cx.notify();
            });
            let links = cx
                .background_spawn(async move {
                    lokalbot_core::projects::build_people_and_projects(&links_library)
                        .map(|(people, projects)| ThreadLinks::new(&people, &projects))
                        .inspect_err(|err| log::warn!("reading people and projects: {err:#}"))
                        .unwrap_or_default()
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.reloads != reload {
                    return;
                }
                this.links = Rc::new(links);
                this.generation += 1;
                cx.notify();
            });
        })
        .detach();
    }

    fn update_filter(&mut self, change: impl FnOnce(&mut ListFilter), cx: &mut Context<Self>) {
        let mut next = self.filter.clone();
        change(&mut next);
        if next != self.filter {
            self.filter = next;
            self.kept.clear();
            self.kept_revision += 1;
            cx.notify();
        }
    }

    fn clear_filters(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        self.search
            .update(cx, |input, cx| input.set_value("", window, cx));
        self.update_filter(ListFilter::clear_filters, cx);
    }

    fn content(&mut self) -> Rc<ListContent> {
        let today = Local::now().date_naive();
        let key = ContentKey {
            generation: self.generation,
            filter: self.filter.clone(),
            kept: self.kept_revision,
            today,
            language: lokalbot_i18n::current().code,
        };
        if let Some((built, content)) = &self.content
            && *built == key
        {
            return content.clone();
        }
        let same_view = self
            .content
            .as_ref()
            .is_some_and(|(built, _)| built.filter == key.filter);
        let content = Rc::new(ListContent::build(
            &self.loaded.threads,
            &self.filter,
            &self.links,
            &self.kept,
            today,
        ));
        let mut entries = Vec::new();
        let mut entry_of_row = HashMap::new();
        if !content.is_empty() {
            entries.push(Entry::Gap(6.));
            for (section_ix, section) in content.sections.iter().enumerate() {
                if section.title.is_some() {
                    entries.push(Entry::Heading(section_ix));
                }
                for (row_ix, row) in section.rows.iter().enumerate() {
                    entry_of_row.insert(row.id.clone(), entries.len());
                    entries.push(Entry::Row(section_ix, row_ix));
                }
            }
            entries.push(Entry::Gap(24.));
        }
        let scroll = self.list_state.logical_scroll_top();
        let old = self.list_state.item_count();
        self.list_state.splice(0..old, entries.len());
        if same_view && scroll.item_ix < entries.len() {
            self.list_state.scroll_to(scroll);
        } else {
            self.list_state.scroll_to(ListOffset::default());
        }
        self.entries = entries;
        self.entry_of_row = entry_of_row;
        self.content = Some((key, content.clone()));
        content
    }

    fn thread(&self, id: &str) -> Option<&ActionThread> {
        self.loaded.threads.iter().find(|t| t.id == id)
    }

    fn current_threads(&self, content: &ListContent) -> Vec<ActionThread> {
        self.selection
            .current(&content.order)
            .iter()
            .filter_map(|id| content.row(id))
            .filter_map(|row| self.loaded.threads.get(row.thread))
            .cloned()
            .collect()
    }

    fn click_row(
        &mut self,
        id: &str,
        modifiers: gpui_kit::Modifiers,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some((_, content)) = &self.content else {
            return;
        };
        let order = content.order.clone();
        self.selection
            .click(id, modifiers.secondary(), modifiers.shift, &order);
        window.focus(&self.list_focus, cx);
        cx.notify();
    }

    fn on_list_key(
        &mut self,
        event: &gpui_kit::KeyDownEvent,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some((_, content)) = &self.content else {
            return;
        };
        let order = content.order.clone();
        let keystroke = &event.keystroke;
        match keystroke.key.as_str() {
            "up" | "down" => {
                let by = if keystroke.key == "up" { -1 } else { 1 };
                if let Some(id) = self.selection.step(by, keystroke.modifiers.shift, &order)
                    && let Some(entry) = self.entry_of_row.get(&id)
                {
                    self.list_state.scroll_to_reveal_item(*entry);
                }
            }
            "escape" if self.selection.current(&order).len() > 1 => {
                self.selection.collapse(&order);
            }
            "a" if keystroke.modifiers.secondary() => self.selection.select_all(&order),
            _ => return,
        }
        cx.stop_propagation();
        cx.notify();
    }

    fn request_status(
        &mut self,
        status: ActionStatus,
        threads: Vec<ActionThread>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let changing = model::changing(threads, status);
        if changing.is_empty() {
            return;
        }
        if !changing.iter().any(|t| t.meeting_count() > 1) {
            self.apply_status(status, changing, cx);
            return;
        }
        let meetings = model::confirmation_meetings(&changing);
        let title = lokalbot_i18n::fill(
            lokalbot_i18n::tr("Update actions in %lld meetings?"),
            &[&lokalbot_i18n::number(meetings.len())],
        );
        let confirm = match status {
            ActionStatus::Done => lokalbot_i18n::tr("Mark all done"),
            ActionStatus::Deferred => lokalbot_i18n::tr("Mark all deferred"),
            ActionStatus::Open => lokalbot_i18n::tr("Mark all open"),
        };
        let page = cx.entity().downgrade();
        window.open_dialog(cx, move |dialog, _, cx| {
            let lb = cx.lb().clone();
            let page = page.clone();
            let changing = changing.clone();
            dialog
                .w(px(420.))
                .title(
                    div()
                        .text_size(ty::COLUMN_TITLE)
                        .font_weight(FontWeight::BOLD)
                        .child(crate::ui::text::paragraph(title.clone())),
                )
                .child(
                    v_flex()
                        .gap(px(2.))
                        .text_size(ty::BODY)
                        .text_color(lb.text_secondary)
                        .children(meetings.iter().map(|t| div().child(t.clone()))),
                )
                .footer(
                    h_flex()
                        .w_full()
                        .gap_2()
                        .justify_end()
                        .child(
                            controls::bordered(
                                "actions-confirm-cancel",
                                lokalbot_i18n::tr("Cancel"),
                            )
                            .on_click(|_, window, cx| window.close_dialog(cx)),
                        )
                        .child(
                            Button::new("actions-confirm")
                                .primary()
                                .label(confirm)
                                .on_click(move |_, window, cx| {
                                    let changing = changing.clone();
                                    let _ = page.update(cx, |this, cx| {
                                        this.apply_status(status, changing, cx)
                                    });
                                    window.close_dialog(cx);
                                }),
                        ),
                )
        });
    }

    fn apply_status(
        &mut self,
        status: ActionStatus,
        threads: Vec<ActionThread>,
        cx: &mut Context<Self>,
    ) {
        self.kept.extend(threads.iter().map(|t| t.id.clone()));
        self.kept_revision += 1;
        cx.notify();
        let library = self.data.read(cx).library.clone();
        let data = self.data.clone();
        cx.spawn(async move |_, cx| {
            let count = threads.len();
            let failures = cx
                .background_spawn(async move {
                    let mut failures: Vec<(String, String)> = Vec::new();
                    for thread in &threads {
                        if let Err(err) = library.set_thread_status(thread, status) {
                            log::warn!("action status: {err:#}");
                            failures.push((thread.text.clone(), format!("{err:#}")));
                        }
                    }
                    failures
                })
                .await;
            data.update(cx, |data, cx| {
                if let Some((_, reason)) = failures.first().filter(|_| count == 1) {
                    data.show_error(
                        lokalbot_i18n::format(
                            "Could not update this action thread. {err}",
                            &[("err", reason.clone())],
                        ),
                        cx,
                    );
                } else if !failures.is_empty() {
                    let texts: Vec<String> = failures.into_iter().map(|(text, _)| text).collect();
                    data.show_error(
                        lokalbot_i18n::format("Could not update: {0}", &[("0", texts.join("; "))]),
                        cx,
                    );
                }
                data.mark_library_changed(cx);
            });
        })
        .detach();
    }

    fn save_corrections(&mut self, corrections: Vec<model::Correction>, cx: &mut Context<Self>) {
        let data = self.data.read(cx);
        let library = data.library.clone();
        let meetings: Vec<lokalbot_core::Meeting> = corrections
            .iter()
            .filter_map(|c| data.meeting(c.meeting_id).cloned())
            .collect();
        let data = self.data.clone();
        cx.spawn(async move |_, cx| {
            let result = cx
                .background_spawn(async move {
                    for correction in corrections {
                        let Some(meeting) = meetings.iter().find(|m| m.id == correction.meeting_id)
                        else {
                            anyhow::bail!("This action is no longer available.");
                        };
                        library.correct_action(
                            meeting,
                            &correction.action_id,
                            correction.change,
                        )?;
                    }
                    Ok(())
                })
                .await;
            data.update(cx, |data, cx| {
                if let Err(err) = result {
                    data.show_error(
                        lokalbot_i18n::format(
                            "Could not update this action. {err}",
                            &[("err", format!("{err:#}"))],
                        ),
                        cx,
                    );
                }
                data.mark_library_changed(cx);
            });
        })
        .detach();
    }

    fn not_mine(&mut self, thread: &ActionThread, cx: &mut Context<Self>) {
        self.save_corrections(model::not_mine_corrections(thread), cx);
    }

    fn edit(&mut self, thread: &ActionThread, window: &mut Window, cx: &mut Context<Self>) {
        let reference = thread.latest().clone();
        let Some(meeting) = self.data.read(cx).meeting(reference.meeting_id).cloned() else {
            return;
        };
        let resolved = reference.resolved_due_date;
        let action = meeting_model::meeting_action(reference, &Speakers::default());
        crate::pages::meetings::dialogs::CorrectionSheet::open_with_date(
            self.data.clone(),
            meeting,
            action,
            resolved,
            window,
            cx,
        );
    }

    fn row_handlers(
        &self,
        thread: &ActionThread,
        cx: &mut Context<Self>,
    ) -> (
        action_row::OnRowClick,
        action_row::OnStatus,
        action_row::OnRowAction,
        action_row::OnRowAction,
    ) {
        let page = cx.entity().downgrade();
        let id = thread.id.clone();
        let on_click = {
            let page = page.clone();
            Rc::new(
                move |event: &gpui_kit::ClickEvent, window: &mut Window, cx: &mut gpui_kit::App| {
                    let _ = page.update(cx, |this, cx| {
                        this.click_row(&id, event.modifiers(), window, cx)
                    });
                },
            )
        };
        let on_status = {
            let page = page.clone();
            let thread = thread.clone();
            Rc::new(move |status, window: &mut Window, cx: &mut gpui_kit::App| {
                let thread = thread.clone();
                let _ = page.update(cx, |this, cx| {
                    this.request_status(status, vec![thread], window, cx)
                });
            })
        };
        let on_edit = {
            let page = page.clone();
            let thread = thread.clone();
            Rc::new(move |window: &mut Window, cx: &mut gpui_kit::App| {
                let _ = page.update(cx, |this, cx| this.edit(&thread, window, cx));
            })
        };
        let on_not_mine = {
            let thread = thread.clone();
            Rc::new(move |_: &mut Window, cx: &mut gpui_kit::App| {
                let _ = page.update(cx, |this, cx| this.not_mine(&thread, cx));
            })
        };
        (on_click, on_status, on_edit, on_not_mine)
    }
}

impl Page for ActionsPage {
    fn title(&self, _cx: &gpui_kit::App) -> SharedString {
        lokalbot_i18n::tr("Actions").into()
    }

    fn subtitle(&self, cx: &gpui_kit::App) -> Option<SharedString> {
        let open = self.data.read(cx).open_action_count?;
        Some(
            lokalbot_i18n::directional(lokalbot_i18n::mac(
                "%lld open",
                &[&lokalbot_i18n::number(open)],
            ))
            .into(),
        )
    }

    fn toolbar(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let open: Vec<ActionThread> = self
            .loaded
            .threads
            .iter()
            .filter(|t| t.status() == ActionStatus::Open)
            .cloned()
            .collect();
        let plan = (!open.is_empty()).then(|| {
            let open = lokalbot_core::actions::attention_sorted(open, Local::now().date_naive());
            let prompt = lokalbot_core::agent_handoff::agent_prompt_for_plan(&open);
            let data = self.data.clone();
            Button::new("actions-plan-in-agent")
                .ghost()
                .icon(Icon::new(Ico::WandSparkles))
                .label(lokalbot_i18n::tr("Plan in Agent…"))
                .tooltip(lokalbot_i18n::tr(
                    "Open a new Agent task with these action threads",
                ))
                .on_click(move |_, _, cx| {
                    let prompt = prompt.clone();
                    data.update(cx, |data, cx| data.open_agent(prompt, cx));
                })
        });
        Some(
            h_flex()
                .gap_1()
                .items_center()
                .children(plan)
                .child(
                    controls::toolbar_icon(
                        "actions-details-toggle",
                        Ico::PanelRight,
                        lokalbot_i18n::tr("Details"),
                    )
                    .when(!self.details_hidden, |this| this.selected(true))
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.details_hidden = !this.details_hidden;
                        cx.notify();
                    })),
                )
                .into_any_element(),
        )
    }
}

impl Render for ActionsPage {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.loaded_revision.is_none() {
            self.reload(window, cx);
        }
        let lb = cx.lb().clone();
        let content = self.content();
        let current = self.current_threads(&content);
        let single = (current.len() == 1).then(|| current[0].clone());
        self.sync_passages(single.as_ref(), cx);
        if self
            .due_picker
            .as_ref()
            .is_some_and(|p| single.as_ref().is_none_or(|t| t.id != p.thread_id))
        {
            self.due_picker = None;
        }
        let list = self.render_list_column(&content, window, cx);
        let body: AnyElement = if self.details_hidden {
            div().size_full().child(list).into_any_element()
        } else {
            let details = self.render_details(&content, current, window, cx);
            if lokalbot_i18n::current().rtl {
                ui::split::leading(
                    "LokalBot.actions",
                    px(DETAILS_WIDTH),
                    ui::split::DETAILS_RANGE,
                    details,
                    list,
                    &self.data,
                    cx,
                )
                .into_any_element()
            } else {
                ui::split::trailing(
                    "LokalBot.actions",
                    px(DETAILS_WIDTH),
                    ui::split::DETAILS_RANGE,
                    list,
                    details,
                    &self.data,
                    cx,
                )
                .into_any_element()
            }
        };
        div().size_full().bg(lb.window).child(body)
    }
}
