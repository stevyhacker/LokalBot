//! Projects (`ProjectsWorkspaceView.swift`, `ProjectPageView.swift`): the
//! projects you track, plus suggestions (names that recur across meetings
//! and overnight review projects nobody tracks yet). The list shows tracked
//! projects by last activity, then suggestions with where each came from.
//! A tracked project's page leads with "Where it stands", the one block a
//! model wrote, then the facts that name the project: your actions, what is
//! waiting on others, decisions and meetings; window time, people and names
//! sit in a side column. A suggestion's page opens on the decision, and a
//! project nothing names yet is one message.

mod detail;
mod list;
mod model;

use std::cell::Cell;
use std::collections::HashMap;
use std::rc::Rc;

use chrono::Utc;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenu, PopupMenuItem};
use gpui_kit::component::{Disableable as _, Icon, WindowExt as _, v_flex};
use gpui_kit::{
    AnyElement, App, AppContext as _, Bounds, Context, Entity, IntoElement, ParentElement as _,
    Pixels, Render, ScrollHandle, SharedString, Styled as _, Subscription, Window, canvas, div, px,
};
use lokalbot_core::action_completion::CompletionHint;
use lokalbot_core::{ProjectCuration, ProjectProfile, TrackedProject, clean_other_names};
use uuid::Uuid;

use self::model::{ListContent, selection_id};
use crate::i18n::h_flex;
use crate::pages::Page;
use crate::state::{AppData, AskRequest, MeetingTab};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};
use lokalbot_i18n::fill;

pub struct ProjectsPage {
    data: Entity<AppData>,
    projects: Vec<ProjectProfile>,
    curation: ProjectCuration,
    loaded: bool,
    loaded_revision: Option<u64>,
    /// The project the page shows; with nothing chosen, the first row.
    selected: Option<String>,
    search: Entity<InputState>,
    query: String,
    name_input: Entity<InputState>,
    other_names_input: Entity<InputState>,
    /// "Looks done?" suggestions, by thread.
    hints: HashMap<String, CompletionHint>,
    /// The tracked project and library revision last offered an automatic
    /// note, so one is asked for when the project or its evidence changes.
    note_considered: Option<(String, Option<u64>)>,
    /// The page's own state, reset when another project opens.
    shows_all_others: bool,
    shows_all_meetings: bool,
    list_scroll: ScrollHandle,
    detail_scroll: ScrollHandle,
    /// The whole page, for the toolbar's compact form.
    page_bounds: Rc<Cell<Option<Bounds<Pixels>>>>,
    /// The project's pane, for where the side column goes.
    detail_bounds: Rc<Cell<Option<Bounds<Pixels>>>>,
    _subscriptions: Vec<Subscription>,
}

impl ProjectsPage {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let data = AppData::global(cx);
        let search = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                "Search projects",
                window,
                cx,
            ))
        });
        let name_input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder("Name", window, cx))
        });
        let other_names_input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                "Codenames or clients, separated by commas",
                window,
                cx,
            ))
        });
        let subscriptions = vec![
            cx.observe(&data, |this, data, cx| {
                if this.loaded_revision != Some(data.read(cx).revision) {
                    this.reload(cx);
                }
                if data.read(cx).project_focus.is_some() {
                    this.take_focus(cx);
                }
            }),
            cx.subscribe_in(&search, window, |this, input, event: &InputEvent, _, cx| {
                if matches!(event, InputEvent::Change) {
                    this.query = input.read(cx).value().to_string();
                    cx.notify();
                }
            }),
        ];
        let mut page = Self {
            data,
            projects: Vec::new(),
            curation: ProjectCuration::default(),
            loaded: false,
            loaded_revision: None,
            selected: None,
            search,
            query: String::new(),
            name_input,
            other_names_input,
            hints: HashMap::new(),
            note_considered: None,
            shows_all_others: false,
            shows_all_meetings: false,
            list_scroll: ScrollHandle::new(),
            detail_scroll: ScrollHandle::new(),
            page_bounds: Rc::new(Cell::new(None)),
            detail_bounds: Rc::new(Cell::new(None)),
            _subscriptions: subscriptions,
        };
        page.reload(cx);
        page
    }

    fn reload(&mut self, cx: &mut Context<Self>) {
        crate::agent_handoff::refresh_in_background();
        let library = self.data.read(cx).library.clone();
        let suggest_done = crate::ui::action_row::suggests_completion(&self.data.read(cx).settings);
        self.loaded_revision = Some(self.data.read(cx).revision);
        cx.spawn(async move |this, cx| {
            let loaded = cx
                .background_spawn(async move {
                    let projects = library.projects();
                    let hints = match &projects {
                        Ok(projects) if suggest_done => hints_for(&library, projects),
                        _ => Default::default(),
                    };
                    (projects, library.project_curation(), hints)
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                match loaded {
                    (Ok(projects), curation, hints) => {
                        this.projects = projects;
                        this.curation = curation.unwrap_or_default();
                        this.hints = hints;
                    }
                    (Err(err), _, _) => log::warn!("loading projects failed: {err:#}"),
                }
                this.loaded = true;
                cx.notify();
            });
        })
        .detach();
    }

    fn save_curation(
        &mut self,
        curation: ProjectCuration,
        select: Option<String>,
        cx: &mut Context<Self>,
    ) {
        self.curation = curation.clone();
        if let Some(select) = select {
            self.select(Some(select));
        }
        let library = self.data.read(cx).library.clone();
        let data = self.data.clone();
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_spawn(async move { library.save_project_curation(&curation) })
                .await;
            if let Err(err) = result {
                data.update(cx, |data, cx| {
                    data.show_error(
                        lokalbot_i18n::format(
                            "Could not save project changes: {err}",
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

    /// `ProjectStore.track`: adds a tracked project and opens it, or opens the
    /// one already known by that name.
    fn track(&mut self, name: &str, other_names: Vec<String>, cx: &mut Context<Self>) {
        let cleaned = name.split_whitespace().collect::<Vec<_>>().join(" ");
        if cleaned.is_empty() {
            return;
        }
        if let Some(existing) = self.curation.tracked_named(&cleaned) {
            self.select(Some(selection_id(existing.id)));
            cx.notify();
            return;
        }
        let key = lokalbot_core::people::normalized(&cleaned);
        let mut curation = self.curation.clone();
        let id = Uuid::new_v4();
        let others = clean_other_names(&other_names, &cleaned);
        curation.tracked.push(TrackedProject {
            id,
            name: cleaned,
            other_names: others,
            created_at: lokalbot_core::time::now_seconds(),
        });
        curation.hidden_names.retain(|n| n != &key);
        self.save_curation(curation, Some(selection_id(id)), cx);
    }

    /// `ProjectStore.update`: the project's name and other names.
    fn rename(&mut self, id: Uuid, name: &str, other_names: Vec<String>, cx: &mut Context<Self>) {
        let cleaned = name.split_whitespace().collect::<Vec<_>>().join(" ");
        if cleaned.is_empty() {
            return;
        }
        let mut curation = self.curation.clone();
        let Some(project) = curation.tracked.iter_mut().find(|p| p.id == id) else {
            return;
        };
        project.other_names = clean_other_names(&other_names, &cleaned);
        project.name = cleaned;
        self.save_curation(curation, None, cx);
    }

    /// Stopping is an explicit removal: the project's note goes with it
    /// (`ProjectStore.stopTracking`).
    fn stop_tracking(&mut self, id: Uuid, cx: &mut Context<Self>) {
        let mut curation = self.curation.clone();
        curation.tracked.retain(|p| p.id != id);
        self.select(None);
        self.save_curation(curation, None, cx);
        self.remove_note(id, cx);
    }

    /// `ProjectStore.merge`: the source's names move to the target, and its
    /// note is discarded.
    fn merge(&mut self, source: Uuid, target: Uuid, cx: &mut Context<Self>) {
        let mut curation = self.curation.clone();
        if curation.merge(source, target) {
            self.save_curation(curation, Some(selection_id(target)), cx);
            self.remove_note(source, cx);
        }
    }

    /// `ProjectStore.addName`: a suggestion becomes a name of a tracked
    /// project, which opens.
    fn add_name(&mut self, name: &str, target: Uuid, cx: &mut Context<Self>) {
        let mut curation = self.curation.clone();
        if curation.add_name(name, target) {
            self.save_curation(curation, Some(selection_id(target)), cx);
        }
    }

    fn remove_note(&mut self, id: Uuid, cx: &mut Context<Self>) {
        let library = self.data.read(cx).library.clone();
        cx.background_spawn(async move {
            if let Err(err) = library.remove_project_summary(&selection_id(id)) {
                log::warn!("project note not removed: {err:#}");
            }
        })
        .detach();
    }

    /// "Not a project": the name is no longer suggested. The open suggestion
    /// makes way for the next one; hiding another row from its menu leaves
    /// the page where it is.
    fn hide_suggestion(&mut self, project: &ProjectProfile, cx: &mut Context<Self>) {
        let key = lokalbot_core::people::normalized(&project.name);
        if key.is_empty() || self.curation.hidden_names.contains(&key) {
            return;
        }
        let shown = self.selected_project().map(|(p, _)| p.id);
        if shown.as_deref() == Some(project.id.as_str()) {
            let next = self
                .list_content(None)
                .selection_after_removing(&project.id);
            self.select(next);
        }
        let mut curation = self.curation.clone();
        curation.hidden_names.push(key);
        self.save_curation(curation, None, cx);
    }

    fn restore_hidden(&mut self, cx: &mut Context<Self>) {
        if self.curation.hidden_names.is_empty() {
            return;
        }
        let mut curation = self.curation.clone();
        curation.hidden_names.clear();
        self.save_curation(curation, None, cx);
    }

    fn select(&mut self, id: Option<String>) {
        if self.selected != id {
            self.shows_all_others = false;
            self.shows_all_meetings = false;
            self.detail_scroll
                .set_offset(gpui_kit::point(px(0.), px(0.)));
        }
        self.selected = id;
    }

    /// Opens a project another page asked to show; it may sit below the
    /// fold of the list.
    fn take_focus(&mut self, cx: &mut Context<Self>) {
        if let Some(id) = self.data.update(cx, |data, _| data.project_focus.take()) {
            if let Some(index) = self.list_content(None).child_index(&id) {
                self.list_scroll.scroll_to_item(index);
            }
            self.select(Some(id));
            cx.notify();
        }
    }

    /// A suggestion tracked a moment ago, as the tracked project it became.
    fn settling(&self) -> Option<ProjectProfile> {
        model::settling_profile(self.selected.as_deref(), &self.curation, &self.projects)
    }

    fn list_content(&self, settling: Option<&ProjectProfile>) -> ListContent {
        let shown = model::list_projects(&self.projects, settling);
        ListContent::build(&shown, &self.curation.hidden_names, &self.query, Utc::now())
    }

    /// The project the page shows and whether it is still settling. With
    /// nothing chosen, the first row: the most recently active tracked
    /// project, else the first suggestion.
    fn selected_project(&self) -> Option<(ProjectProfile, bool)> {
        match &self.selected {
            Some(id) => {
                if let Some(settling) = self.settling().filter(|s| &s.id == id) {
                    return Some((settling, true));
                }
                self.projects
                    .iter()
                    .find(|p| &p.id == id)
                    .map(|p| (p.clone(), false))
            }
            None => {
                let content = self.list_content(None);
                let first = content.project_ids().next()?;
                self.projects
                    .iter()
                    .find(|p| p.id == first)
                    .map(|p| (p.clone(), false))
            }
        }
    }

    /// Opening a tracked project writes or refreshes its note when that is
    /// due (`writeProjectSummary(for:automatic:)`); the engine decides. A
    /// project still settling waits for its own evidence.
    fn consider_note(&mut self, cx: &App) {
        let Some(id) = self
            .selected_project()
            .filter(|(project, settling)| project.is_tracked() && !settling)
            .map(|(project, _)| project.id)
        else {
            return;
        };
        let current = (id.clone(), self.loaded_revision);
        if self.note_considered.as_ref() != Some(&current) {
            self.note_considered = Some(current);
            crate::bridge::send(lokalbot_engine::Command::ProjectOpened(id), cx);
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

    /// Names a tracked project (`ProjectNameSheet`): "Track a project" from
    /// the + button, "Names for …" from Edit names…, which starts on other
    /// names.
    fn open_name_sheet(
        &mut self,
        editing: Option<(Uuid, String, Vec<String>)>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let (name, others) = editing
            .as_ref()
            .map(|(_, n, o)| (n.clone(), o.join(", ")))
            .unwrap_or_default();
        self.name_input
            .update(cx, |input, cx| input.set_value(name.clone(), window, cx));
        self.other_names_input
            .update(cx, |input, cx| input.set_value(others, window, cx));
        let page = cx.entity();
        let (name_input, others_input) = (self.name_input.clone(), self.other_names_input.clone());
        let (title, action): (SharedString, SharedString) = match &editing {
            Some(_) => (
                fill(lokalbot_i18n::tr("Names for %@"), &[&name]).into(),
                lokalbot_i18n::tr("Save").into(),
            ),
            None => (
                lokalbot_i18n::tr("Track a project").into(),
                lokalbot_i18n::tr("Track").into(),
            ),
        };
        let focus = if editing.is_some() {
            others_input.clone()
        } else {
            name_input.clone()
        };
        let target = editing.map(|(id, _, _)| id);
        window.open_dialog(cx, move |dialog, _, cx| {
            let lb = cx.lb().clone();
            let page = page.clone();
            let (name_input, others_input) = (name_input.clone(), others_input.clone());
            let field = |label: &'static str, input: &Entity<InputState>| {
                v_flex()
                    .gap(px(5.))
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text)
                            .child(label),
                    )
                    .child(Input::new(input))
            };
            let empty = name_input.read(cx).value().trim().is_empty();
            let (save_name, save_others) = (name_input.clone(), others_input.clone());
            dialog.title(title.clone()).w(px(440.)).child(
                v_flex()
                    .gap(px(12.))
                    .child(field(lokalbot_i18n::tr("Name"), &name_input))
                    .child(field(lokalbot_i18n::tr("Other names"), &others_input))
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(ui::text::paragraph(lokalbot_i18n::tr(
                                "Meetings, actions, and window titles that use any of these names are linked to the project.",
                            ))),
                    )
                    .child(
                        h_flex()
                            .gap(px(8.))
                            .pt(px(4.))
                            .child(div().flex_1().min_w_0())
                            .child(
                                Button::new("project-sheet-cancel")
                                    .outline()
                                    .label(lokalbot_i18n::tr("Cancel"))
                                    .on_click(|_, window, cx| window.close_dialog(cx)),
                            )
                            .child(
                                Button::new("project-sheet-save")
                                    .primary()
                                    .label(action.clone())
                                    .disabled(empty)
                                    .on_click(move |_, window, cx| {
                                        let name = save_name.read(cx).value().to_string();
                                        if name.trim().is_empty() {
                                            return;
                                        }
                                        let others: Vec<String> = save_others
                                            .read(cx)
                                            .value()
                                            .split(',')
                                            .map(|s| s.trim().to_string())
                                            .filter(|s| !s.is_empty())
                                            .collect();
                                        page.update(cx, |page, cx| match target {
                                            Some(id) => page.rename(id, &name, others, cx),
                                            None => page.track(&name, others, cx),
                                        });
                                        window.close_dialog(cx);
                                    }),
                            ),
                    ),
            )
        });
        // Typing starts in the name, or in other names when adding one.
        focus.update(cx, |input, cx| input.focus(window, cx));
    }

    /// Edit names on a tracked project.
    fn edit_names(
        &mut self,
        project: &ProjectProfile,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(id) = project.tracked_id() {
            let editing = Some((id, project.name.clone(), project.other_names.clone()));
            self.open_name_sheet(editing, window, cx);
        }
    }

    /// Ask about the project, words and icon while the toolbar has room and
    /// the icon alone when it does not (a project nothing names has nothing
    /// to ask about); then the "…" menu for a tracked project.
    fn render_toolbar(&self, project: &ProjectProfile, cx: &mut Context<Self>) -> AnyElement {
        let mut items = h_flex().gap(px(4.)).items_center();
        if !model::is_empty(project) {
            let label: SharedString =
                fill(lokalbot_i18n::tr("Ask about %@"), &[&project.name]).into();
            let ask_data = self.data.clone();
            let question = lokalbot_i18n::format(
                "What is the latest on {0}?",
                &[("0", project.name.to_string())],
            );
            let meeting_ids: Vec<Uuid> = project.meetings.iter().map(|m| m.id).collect();
            let ask = Button::new("project-ask")
                .icon(Icon::new(Ico::Search))
                .tooltip(label.clone())
                .on_click(move |_, _, cx| {
                    let request = AskRequest {
                        question: question.clone(),
                        meeting_ids: meeting_ids.clone(),
                        submit: false,
                        day: None,
                    };
                    ask_data.update(cx, |data, cx| data.ask(request, cx));
                });
            items = items.child(if self.compact_toolbar() {
                ask.ghost()
            } else {
                ask.secondary().label(label)
            });
        }
        if project.is_tracked() {
            let page = cx.entity();
            let menu_project = project.clone();
            let tracked = self.curation.tracked.clone();
            items = items.child(
                Button::new("project-more")
                    .ghost()
                    .icon(Icon::new(Ico::Ellipsis))
                    .tooltip(lokalbot_i18n::tr("More"))
                    .dropdown_menu(move |menu, window, cx| {
                        project_menu(menu, &page, &menu_project, &tracked, window, cx)
                    }),
            );
        }
        items.into_any_element()
    }
}

/// "Looks done?" for the open work of yours on each project, only with consent.
fn hints_for(
    library: &lokalbot_core::Library,
    projects: &[ProjectProfile],
) -> HashMap<String, CompletionHint> {
    let mut threads: Vec<lokalbot_core::ActionThread> = Vec::new();
    for thread in projects.iter().flat_map(|p| p.my_actions.iter()) {
        if thread.status() == lokalbot_core::ActionStatus::Open
            && !threads.iter().any(|t| t.id == thread.id)
        {
            threads.push(thread.clone());
        }
    }
    library.action_completion_hints(&threads, Utc::now())
}

/// "Add to a project": one item per tracked project.
fn add_name_items(
    menu: PopupMenu,
    page: &Entity<ProjectsPage>,
    name: &str,
    tracked: &[TrackedProject],
) -> PopupMenu {
    let mut menu = menu;
    for target in tracked {
        let page = page.clone();
        let name = name.to_string();
        let id = target.id;
        menu = menu.item(
            PopupMenuItem::new(target.name.clone())
                .on_click(move |_, _, cx| page.update(cx, |page, cx| page.add_name(&name, id, cx))),
        );
    }
    menu
}

/// A row's context menu and the page's "…" menu (`ProjectMenuItems`): names,
/// merge and stop for a tracked project; the three answers for a suggestion.
fn project_menu(
    menu: PopupMenu,
    page: &Entity<ProjectsPage>,
    project: &ProjectProfile,
    tracked: &[TrackedProject],
    window: &mut Window,
    cx: &mut Context<PopupMenu>,
) -> PopupMenu {
    let page = page.clone();
    if let Some(id) = project.tracked_id() {
        let names_page = page.clone();
        let stop_page = page.clone();
        let names_project = project.clone();
        let others_tracked: Vec<TrackedProject> =
            tracked.iter().filter(|t| t.id != id).cloned().collect();
        let mut menu = menu.item(
            PopupMenuItem::new(lokalbot_i18n::tr("Edit names…")).on_click(move |_, window, cx| {
                let project = names_project.clone();
                names_page.update(cx, |page, cx| page.edit_names(&project, window, cx))
            }),
        );
        if !others_tracked.is_empty() {
            let merge_page = page.clone();
            menu = menu.submenu(
                lokalbot_i18n::tr("Merge into"),
                window,
                cx,
                move |submenu, _, _| {
                    let mut submenu = submenu;
                    for target in &others_tracked {
                        let page = merge_page.clone();
                        let target_id = target.id;
                        submenu = submenu.item(PopupMenuItem::new(target.name.clone()).on_click(
                            move |_, _, cx| {
                                page.update(cx, |page, cx| page.merge(id, target_id, cx))
                            },
                        ));
                    }
                    submenu
                },
            );
        }
        menu.separator().item(
            PopupMenuItem::new(lokalbot_i18n::tr("Stop tracking")).on_click(move |_, _, cx| {
                stop_page.update(cx, |page, cx| page.stop_tracking(id, cx))
            }),
        )
    } else {
        let track_page = page.clone();
        let hide_page = page.clone();
        let track_name = project.name.clone();
        let hide_project = project.clone();
        let mut menu = menu.item(PopupMenuItem::new(lokalbot_i18n::tr("Track")).on_click(
            move |_, _, cx| {
                let name = track_name.clone();
                track_page.update(cx, |page, cx| page.track(&name, Vec::new(), cx))
            },
        ));
        if !tracked.is_empty() {
            let add_page = page.clone();
            let add_name = project.name.clone();
            let tracked: Vec<TrackedProject> = tracked.to_vec();
            menu = menu.submenu(
                lokalbot_i18n::tr("Add to a project"),
                window,
                cx,
                move |submenu, _, _| add_name_items(submenu, &add_page, &add_name, &tracked),
            );
        }
        menu.separator().item(
            PopupMenuItem::new(lokalbot_i18n::tr("Not a project")).on_click(move |_, _, cx| {
                let project = hide_project.clone();
                hide_page.update(cx, |page, cx| page.hide_suggestion(&project, cx))
            }),
        )
    }
}

impl Page for ProjectsPage {
    /// The selected project is the window's title, with when it was last
    /// active beside it.
    fn title(&self, _cx: &App) -> SharedString {
        match self.selected_project() {
            Some((project, _)) => project.name.into(),
            None => lokalbot_i18n::tr("Projects").into(),
        }
    }

    fn subtitle(&self, _cx: &App) -> Option<SharedString> {
        let (project, _) = self.selected_project()?;
        let tracked_since = project
            .tracked_id()
            .and_then(|id| self.curation.tracked.iter().find(|t| t.id == id))
            .map(|t| t.created_at);
        Some(model::subtitle(&project, tracked_since, Utc::now()).into())
    }

    fn toolbar(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> Option<AnyElement> {
        let (project, _) = self.selected_project()?;
        Some(self.render_toolbar(&project, cx))
    }
}

impl Render for ProjectsPage {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        if self.loaded {
            self.consider_note(cx);
        }
        let detail = match self.selected_project() {
            Some((project, settling)) => self.render_detail(&project, settling, cx),
            None => div()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .text_size(ty::BODY)
                .text_color(lb.text_secondary)
                .child(
                    // A project tracked a moment ago appears after the next
                    // load.
                    if !self.loaded
                        || self
                            .selected
                            .as_deref()
                            .is_some_and(|id| id.starts_with("tracked:"))
                    {
                        lokalbot_i18n::tr("Loading projects…")
                    } else {
                        lokalbot_i18n::tr("Select a project.")
                    },
                )
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
                "LokalBot.projects",
                metric::CONTENT_COLUMN_WIDTH,
                ui::split::LIST_RANGE,
                list,
                div()
                    .size_full()
                    .relative()
                    .bg(lb.page)
                    .child(measure_detail)
                    .child(detail),
                &self.data,
                cx,
            ))
    }
}
