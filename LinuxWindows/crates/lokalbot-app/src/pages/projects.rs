//! Projects (`ProjectsWorkspaceView.swift`): tracked projects and names
//! that keep coming up, with each project's note, actions, decisions,
//! time, people and meetings.

use crate::i18n::h_flex;
use chrono::{Local, Utc};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputState};
use gpui_kit::component::menu::{ContextMenuExt as _, DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Entity, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, Render, ScrollHandle, SharedString,
    StatefulInteractiveElement as _, Styled as _, Subscription, Window, div, px,
};
use lokalbot_core::{ProjectCuration, ProjectProfile, TrackedProject};
use uuid::Uuid;

use crate::pages::Page;
use crate::state::{AppData, AppEvent, AskRequest, MeetingTab};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico, profile};

/// Suggestions come from names seen in at least this many meetings.
const MINIMUM_MEETINGS: usize = 3;
/// Others' actions and meetings look back this far.
const LOOKBACK_DAYS: i64 = 30;

pub struct ProjectsPage {
    data: Entity<AppData>,
    projects: Vec<ProjectProfile>,
    curation: ProjectCuration,
    loaded: bool,
    loaded_revision: Option<u64>,
    selected: Option<String>,
    name_input: Entity<InputState>,
    other_names_input: Entity<InputState>,
    show_older: bool,
    detail_scroll: ScrollHandle,
    _subscriptions: Vec<Subscription>,
}

impl ProjectsPage {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let data = AppData::global(cx);
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
        let subscriptions = vec![cx.observe(&data, |this, data, cx| {
            if this.loaded_revision != Some(data.read(cx).revision) {
                this.reload(cx);
            }
            if let Some(id) = this.data.update(cx, |data, _| data.project_focus.take()) {
                this.selected = Some(id);
                this.detail_scroll
                    .set_offset(gpui_kit::point(px(0.), px(0.)));
                cx.notify();
            }
        })];
        let mut page = Self {
            data,
            projects: Vec::new(),
            curation: ProjectCuration::default(),
            loaded: false,
            loaded_revision: None,
            selected: None,
            name_input,
            other_names_input,
            show_older: false,
            detail_scroll: ScrollHandle::new(),
            _subscriptions: subscriptions,
        };
        page.reload(cx);
        page
    }

    fn reload(&mut self, cx: &mut Context<Self>) {
        let library = self.data.read(cx).library.clone();
        self.loaded_revision = Some(self.data.read(cx).revision);
        cx.spawn(async move |this, cx| {
            let loaded = cx
                .background_spawn(async move { (library.projects(), library.project_curation()) })
                .await;
            let _ = this.update(cx, |this, cx| {
                match loaded {
                    (Ok(projects), curation) => {
                        this.projects = projects;
                        this.curation = curation.unwrap_or_default();
                    }
                    (Err(err), _) => log::warn!("loading projects failed: {err:#}"),
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
            self.selected = Some(select);
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

    /// `ProjectStore.track`: adds a tracked project, or selects the one with that name.
    fn track(&mut self, name: &str, other_names: Vec<String>, cx: &mut Context<Self>) {
        let cleaned = name.split_whitespace().collect::<Vec<_>>().join(" ");
        if cleaned.is_empty() {
            return;
        }
        let key = lokalbot_core::people::normalized(&cleaned);
        if let Some(existing) = self
            .curation
            .tracked
            .iter()
            .find(|p| lokalbot_core::people::normalized(&p.name) == key)
        {
            self.selected = Some(format!(
                "tracked:{}",
                lokalbot_core::ids::uuid_upper(&existing.id)
            ));
            cx.notify();
            return;
        }
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
        self.save_curation(
            curation,
            Some(format!("tracked:{}", lokalbot_core::ids::uuid_upper(&id))),
            cx,
        );
    }

    fn rename(&mut self, id: Uuid, name: &str, other_names: Vec<String>, cx: &mut Context<Self>) {
        let cleaned = name.split_whitespace().collect::<Vec<_>>().join(" ");
        let mut curation = self.curation.clone();
        let Some(project) = curation.tracked.iter_mut().find(|p| p.id == id) else {
            return;
        };
        if cleaned.is_empty() {
            return;
        }
        project.other_names = clean_other_names(&other_names, &cleaned);
        project.name = cleaned;
        self.save_curation(curation, None, cx);
    }

    fn stop_tracking(&mut self, id: Uuid, cx: &mut Context<Self>) {
        let mut curation = self.curation.clone();
        curation.tracked.retain(|p| p.id != id);
        self.selected = None;
        self.save_curation(curation, None, cx);
    }

    fn hide_suggestion(&mut self, name: &str, cx: &mut Context<Self>) {
        let key = lokalbot_core::people::normalized(name);
        if key.is_empty() || self.curation.hidden_names.contains(&key) {
            return;
        }
        let mut curation = self.curation.clone();
        curation.hidden_names.push(key);
        self.selected = None;
        self.save_curation(curation, None, cx);
    }

    fn restore_hidden(&mut self, cx: &mut Context<Self>) {
        let mut curation = self.curation.clone();
        curation.hidden_names.clear();
        self.save_curation(curation, None, cx);
    }

    /// The Track / Rename sheet (`ProjectNameSheet`).
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
            .update(cx, |input, cx| input.set_value(name, window, cx));
        self.other_names_input
            .update(cx, |input, cx| input.set_value(others, window, cx));
        let page = cx.entity();
        let (name_input, others_input) = (self.name_input.clone(), self.other_names_input.clone());
        let (title, action) = if editing.is_some() {
            (
                lokalbot_i18n::tr("Rename Project"),
                lokalbot_i18n::tr("Save"),
            )
        } else {
            (
                lokalbot_i18n::tr("Track a Project"),
                lokalbot_i18n::tr("Track"),
            )
        };
        let target = editing.map(|(id, _, _)| id);
        window.open_dialog(cx, move |dialog, _, cx| {
            let lb = cx.lb().clone();
            let page = page.clone();
            let (name_input, others_input) = (name_input.clone(), others_input.clone());
            let field = |label: &'static str, input: &Entity<InputState>| {
                v_flex().gap(px(5.)).child(div().text_size(ty::SECONDARY).text_color(lb.text).child(label)).child(Input::new(input))
            };
            let (save_name, save_others) = (name_input.clone(), others_input.clone());
            dialog.title(title).w(px(440.)).child(
                v_flex()
                    .gap(px(12.))
                    .child(field(lokalbot_i18n::tr("Name"), &name_input))
                    .child(field(lokalbot_i18n::tr("Other names"), &others_input))
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Meetings, actions, and window titles that use any of these names are linked to the project."))),
                    )
                    .child(
                        h_flex()
                            .gap(px(8.))
                            .pt(px(4.))
                            .child(div().flex_1().min_w_0())
                            .child(Button::new("project-sheet-cancel").outline().label(lokalbot_i18n::tr("Cancel")).on_click(|_, window, cx| window.close_dialog(cx)))
                            .child(Button::new("project-sheet-save").primary().label(action).on_click(move |_, window, cx| {
                                let name = save_name.read(cx).value().to_string();
                                let others: Vec<String> =
                                    save_others.read(cx).value().split(',').map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).collect();
                                page.update(cx, |page, cx| match target {
                                    Some(id) => page.rename(id, &name, others, cx),
                                    None => page.track(&name, others, cx),
                                });
                                window.close_dialog(cx);
                            })),
                    ),
            )
        });
    }

    fn tracked(&self) -> Vec<&ProjectProfile> {
        self.projects.iter().filter(|p| p.is_tracked()).collect()
    }

    fn suggested(&self) -> Vec<&ProjectProfile> {
        self.projects
            .iter()
            .filter(|p| !p.is_tracked())
            .filter(|p| {
                !self
                    .curation
                    .hidden_names
                    .contains(&lokalbot_core::people::normalized(&p.name))
            })
            .collect()
    }

    fn selected_project(&self) -> Option<&ProjectProfile> {
        match &self.selected {
            Some(id) => self.projects.iter().find(|p| &p.id == id),
            None => self
                .tracked()
                .first()
                .copied()
                .or_else(|| self.suggested().first().copied()),
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

    fn render_list(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let tracked = self.tracked();
        let suggested = self.suggested();
        let summary = if !self.loaded {
            lokalbot_i18n::tr("Loading…").to_string()
        } else {
            let mut parts = Vec::new();
            if !tracked.is_empty() {
                parts.push(lokalbot_i18n::format(
                    "{0} tracked",
                    &[("0", format!("{}", tracked.len()))],
                ));
            }
            if !suggested.is_empty() {
                parts.push(lokalbot_i18n::format(
                    "{0} suggested",
                    &[("0", format!("{}", suggested.len()))],
                ));
            }
            if parts.is_empty() {
                lokalbot_i18n::tr("None yet").into()
            } else {
                parts.join(" · ")
            }
        };
        let selected_id = self.selected_project().map(|p| p.id.clone());
        let mut rows: Vec<AnyElement> = Vec::new();
        let header = |title: &'static str| {
            div()
                .px(px(18.))
                .pt(px(10.))
                .pb(px(4.))
                .text_size(ty::SECONDARY)
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.supporting)
                .child(title)
                .into_any_element()
        };
        if self.loaded && self.projects.is_empty() {
            let page = cx.entity();
            rows.push(
                v_flex()
                    .items_center()
                    .gap(px(12.))
                    .p(px(24.))
                    .child(
                        div().text_center().text_size(ty::SECONDARY).text_color(lb.text_secondary).child(crate::ui::text::paragraph(lokalbot_i18n::format("Add the projects you work on, and LokalBot gathers their meetings, actions, and decisions. It also suggests names that come up in {MINIMUM_MEETINGS} or more meetings.", &[("MINIMUM_MEETINGS", format!("{}", MINIMUM_MEETINGS))]))),
                    )
                    .child(Button::new("projects-track-empty").outline().label(lokalbot_i18n::tr("Track a Project")).on_click(move |_, window, cx| {
                        page.update(cx, |page, cx| page.open_name_sheet(None, window, cx))
                    }))
                    .into_any_element(),
            );
        } else {
            rows.push(header(lokalbot_i18n::tr("Tracked")));
            if tracked.is_empty() {
                rows.push(
                    div()
                        .px(px(18.))
                        .py(px(4.))
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                            "Track a suggestion below, or add a project with +.",
                        )))
                        .into_any_element(),
                );
            }
            for project in &tracked {
                rows.push(self.render_row(
                    project,
                    selected_id.as_deref() == Some(project.id.as_str()),
                    cx,
                ));
            }
            if !suggested.is_empty() {
                rows.push(header(lokalbot_i18n::tr("Suggested")));
                for project in &suggested {
                    rows.push(self.render_row(
                        project,
                        selected_id.as_deref() == Some(project.id.as_str()),
                        cx,
                    ));
                }
            }
            if !self.curation.hidden_names.is_empty() {
                let count = self.curation.hidden_names.len();
                let page = cx.entity();
                rows.push(
                    div()
                        .px(px(18.))
                        .py(px(8.))
                        .child(profile::link(
                            "projects-restore-hidden",
                            lokalbot_i18n::format(
                                "Show hidden suggestions ({count})",
                                &[("count", count.to_string())],
                            ),
                            move |_, cx| page.update(cx, |page, cx| page.restore_hidden(cx)),
                            cx,
                        ))
                        .into_any_element(),
                );
            }
        }
        let page = cx.entity();
        v_flex()
            .w(metric::CONTENT_COLUMN_WIDTH)
            .flex_none()
            .h_full()
            .border_r_1()
            .border_color(lb.separator)
            .child(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .px(px(14.))
                    .pt(px(14.))
                    .pb(px(10.))
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap(px(2.))
                            .child(
                                div()
                                    .text_size(ty::COLUMN_TITLE)
                                    .font_weight(FontWeight::BOLD)
                                    .text_color(lb.text)
                                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                        "Projects",
                                    ))),
                            )
                            .child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.supporting)
                                    .child(summary),
                            ),
                    )
                    .child(
                        Button::new("projects-add")
                            .outline()
                            .small()
                            .icon(Icon::new(Ico::Plus))
                            .tooltip(lokalbot_i18n::tr("Track a project"))
                            .on_click(move |_, window, cx| {
                                page.update(cx, |page, cx| page.open_name_sheet(None, window, cx))
                            }),
                    ),
            )
            .child(
                div()
                    .id("projects-list")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .pb(px(12.))
                    .children(rows),
            )
    }

    fn render_row(
        &self,
        project: &ProjectProfile,
        selected: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let id = project.id.clone();
        let page = cx.entity();
        let menu_project = project.clone();
        h_flex()
            .id(SharedString::from(format!("project-{}", project.id)))
            .mx(px(8.))
            .px(px(10.))
            .py(px(7.))
            .gap(px(10.))
            .items_center()
            .rounded(metric::ROW_RADIUS)
            .cursor_pointer()
            .when(selected, |this| this.bg(lb.sidebar_selection))
            .when(!selected, |this| this.hover(|s| s.bg(lb.hover)))
            .child(profile::monogram(&project.name, px(30.), cx))
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(2.))
                    .child(
                        div()
                            .truncate()
                            .text_size(ty::BODY)
                            .font_weight(FontWeight::MEDIUM)
                            .text_color(lb.text)
                            .child(project.name.clone()),
                    )
                    .child(
                        div()
                            .truncate()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(summary(project, false)),
                    ),
            )
            .on_click(cx.listener(move |this, _, _, cx| {
                this.selected = Some(id.clone());
                this.show_older = false;
                this.detail_scroll
                    .set_offset(gpui_kit::point(px(0.), px(0.)));
                cx.notify();
            }))
            .context_menu(move |menu, _, _| project_menu(menu, &page, &menu_project))
            .into_any_element()
    }

    fn render_detail(&self, project: &ProjectProfile, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let page = cx.entity();
        let mut sections: Vec<AnyElement> = Vec::new();

        // Header.
        let ask_data = self.data.clone();
        let question = lokalbot_i18n::format(
            "What is the latest on {0}?",
            &[("0", project.name.to_string())],
        );
        let meeting_ids: Vec<Uuid> = project.meetings.iter().map(|m| m.id).collect();
        let menu_page = page.clone();
        let menu_project = project.clone();
        sections.push(
            v_flex()
                .gap(px(14.))
                .child(
                    h_flex()
                        .gap(px(14.))
                        .items_center()
                        .child(profile::monogram(&project.name, px(56.), cx))
                        .child(
                            v_flex()
                                .flex_1()
                                .min_w_0()
                                .gap(px(4.))
                                .child(
                                    h_flex()
                                        .gap(px(10.))
                                        .items_center()
                                        .child(
                                            div()
                                                .text_size(ty::PAGE_TITLE)
                                                .font_weight(FontWeight::BOLD)
                                                .text_color(lb.text)
                                                .child(project.name.clone()),
                                        )
                                        .when(!project.is_tracked(), |this| {
                                            this.child(
                                                h_flex()
                                                    .gap(px(4.))
                                                    .items_center()
                                                    .px(px(8.))
                                                    .py(px(2.))
                                                    .rounded_full()
                                                    .bg(lb.accent_wash)
                                                    .text_size(ty::CAPTION)
                                                    .font_weight(FontWeight::SEMIBOLD)
                                                    .text_color(lb.accent_text)
                                                    .child(ui::icon(
                                                        Ico::Sparkles,
                                                        px(11.),
                                                        lb.accent_text,
                                                    ))
                                                    .child(crate::ui::text::paragraph(
                                                        lokalbot_i18n::tr("Suggested"),
                                                    )),
                                            )
                                        }),
                                )
                                .child(
                                    div()
                                        .text_size(ty::SECONDARY)
                                        .text_color(lb.text_secondary)
                                        .child(summary(project, true)),
                                )
                                .when(!project.other_names.is_empty(), |this| {
                                    this.child(
                                        div()
                                            .text_size(ty::SECONDARY)
                                            .text_color(lb.text_secondary)
                                            .child(crate::ui::text::paragraph(
                                                lokalbot_i18n::format(
                                                    "Also: {0}",
                                                    &[(
                                                        "0",
                                                        project.other_names.join(", ").to_string(),
                                                    )],
                                                ),
                                            )),
                                    )
                                }),
                        ),
                )
                .child(
                    h_flex()
                        .gap(px(8.))
                        .child(
                            Button::new("project-ask")
                                .outline()
                                .icon(Icon::new(Ico::TextSearch))
                                .label(lokalbot_i18n::format(
                                    "Ask About {0}",
                                    &[("0", project.name.to_string())],
                                ))
                                .on_click(move |_, _, cx| {
                                    let request = AskRequest {
                                        question: question.clone(),
                                        meeting_ids: meeting_ids.clone(),
                                        submit: false,
                                    };
                                    ask_data.update(cx, |data, cx| data.ask(request, cx));
                                }),
                        )
                        .when(project.is_tracked(), |this| {
                            this.child(
                                Button::new("project-more")
                                    .ghost()
                                    .icon(Icon::new(Ico::Ellipsis))
                                    .label(lokalbot_i18n::tr("More"))
                                    .dropdown_menu(move |menu, _, _| {
                                        project_menu(menu, &menu_page, &menu_project)
                                    }),
                            )
                        }),
                )
                .into_any_element(),
        );

        if project.is_tracked() {
            sections.push(self.render_note(project, cx));
        } else {
            let count = project.meetings.len();
            let track_page = page.clone();
            let hide_page = page.clone();
            let (track_name, hide_name) = (project.name.clone(), project.name.clone());
            sections.push(
                ui::panel(cx)
                    .child(
                        v_flex()
                            .gap(px(10.))
                            .child(div().text_size(ty::BODY).text_color(lb.text).child(crate::ui::text::paragraph(lokalbot_i18n::format("{0} came up in {1}. Track it to keep a note on where it stands, or hide it if it is not a project.", &[("0", project.name.to_string()), ("1", profile::count(count, "meeting").to_string())]))))
                            .child(
                                h_flex()
                                    .gap(px(8.))
                                    .child(Button::new("project-track").primary().icon(Icon::new(Ico::Plus)).label(lokalbot_i18n::format("Track {0}", &[("0", project.name.to_string())])).on_click(
                                        move |_, _, cx| {
                                            let name = track_name.clone();
                                            track_page.update(cx, |page, cx| page.track(&name, Vec::new(), cx))
                                        },
                                    ))
                                    .child(Button::new("project-hide").outline().label(lokalbot_i18n::tr("Not a Project")).on_click(move |_, _, cx| {
                                        let name = hide_name.clone();
                                        hide_page.update(cx, |page, cx| page.hide_suggestion(&name, cx))
                                    })),
                            ),
                    )
                    .into_any_element(),
            );
        }

        let action_rows =
            |threads: &[lokalbot_core::ActionThread], prefix: &str, cx: &mut Context<Self>| {
                let rows: Vec<AnyElement> = threads
                    .iter()
                    .map(|thread| {
                        let page = page.clone();
                        profile::action_row(
                            SharedString::from(format!("{prefix}-{}", thread.id)),
                            thread,
                            move |id, at, _, cx| {
                                page.update(cx, |page, cx| page.open_meeting(id, at, cx))
                            },
                            cx,
                        )
                    })
                    .collect();
                profile::divided(rows, cx)
            };
        if !project.my_actions.is_empty() {
            let rows = action_rows(&project.my_actions, "project-mine", cx);
            sections.push(
                profile::section(Ico::ListChecks, lokalbot_i18n::tr("Your Actions"), rows, cx)
                    .into_any_element(),
            );
        }
        if !project.others_actions.is_empty() || !project.older_others_actions.is_empty() {
            let mut content = v_flex();
            if project.others_actions.is_empty() {
                content = content.child(profile::empty_row(
                    lokalbot_i18n::format(
                        "Nothing from others in the last {LOOKBACK_DAYS} days.",
                        &[("LOOKBACK_DAYS", format!("{}", LOOKBACK_DAYS))],
                    ),
                    cx,
                ));
            } else {
                content = content.child(action_rows(&project.others_actions, "project-others", cx));
            }
            if !project.older_others_actions.is_empty() {
                if self.show_older {
                    content = content.child(action_rows(
                        &project.older_others_actions,
                        "project-older",
                        cx,
                    ));
                }
                let count = project.older_others_actions.len();
                let label = if self.show_older {
                    lokalbot_i18n::tr("Hide older").to_string()
                } else {
                    lokalbot_i18n::format(
                        "Show {0} last mentioned over {LOOKBACK_DAYS} days ago",
                        &[
                            ("0", profile::count(count, "older action").to_string()),
                            ("LOOKBACK_DAYS", format!("{}", LOOKBACK_DAYS)),
                        ],
                    )
                };
                let toggle_page = page.clone();
                content = content.child(div().pt(px(8.)).child(profile::link(
                    "project-older-toggle",
                    label,
                    move |_, cx| {
                        toggle_page.update(cx, |page, cx| {
                            page.show_older = !page.show_older;
                            cx.notify();
                        })
                    },
                    cx,
                )));
            }
            sections.push(
                profile::section(
                    Ico::Users,
                    lokalbot_i18n::tr("Waiting on Others"),
                    content,
                    cx,
                )
                .into_any_element(),
            );
        }
        if !project.decisions.is_empty() {
            let rows: Vec<AnyElement> = project
                .decisions
                .iter()
                .enumerate()
                .map(|(index, (meeting, decision))| {
                    let page = page.clone();
                    let meeting = meeting.clone();
                    let at = decision.citations.first().map(|c| c.start);
                    v_flex()
                        .gap(px(3.))
                        .py(px(6.))
                        .child(
                            div()
                                .text_size(ty::BODY)
                                .text_color(lb.text)
                                .child(decision.display_text()),
                        )
                        .child(profile::link(
                            ("project-decision", index),
                            format!(
                                "{} · {}",
                                meeting.title,
                                profile::short_date(meeting.started_at)
                            ),
                            move |_, cx| {
                                page.update(cx, |page, cx| page.open_meeting(meeting.id, at, cx))
                            },
                            cx,
                        ))
                        .into_any_element()
                })
                .collect();
            sections.push(
                profile::section(
                    Ico::BadgeCheck,
                    lokalbot_i18n::tr("Decisions"),
                    profile::divided(rows, cx),
                    cx,
                )
                .into_any_element(),
            );
        }
        if project.week_seconds >= 60. {
            let mut content = v_flex().gap(px(6.)).child(value_row(
                lokalbot_i18n::tr("Total"),
                profile::duration(project.week_seconds),
                lb.text,
                cx,
            ));
            for (day, seconds) in &project.days {
                content = content.child(value_row(
                    &profile::day_key_label(day),
                    profile::duration(*seconds),
                    lb.text_secondary,
                    cx,
                ));
            }
            if !project.windows.is_empty() {
                content = content.child(ui::divider(cx));
                for window in &project.windows {
                    content = content.child(
                        h_flex()
                            .gap(px(10.))
                            .items_center()
                            .child(
                                v_flex()
                                    .flex_1()
                                    .min_w_0()
                                    .gap(px(1.))
                                    .child(
                                        div()
                                            .truncate()
                                            .text_size(ty::BODY)
                                            .text_color(lb.text)
                                            .child(window.title.clone()),
                                    )
                                    .child(
                                        div()
                                            .text_size(ty::SECONDARY)
                                            .text_color(lb.text_secondary)
                                            .child(window.app.clone()),
                                    ),
                            )
                            .child(
                                div()
                                    .text_size(ty::BODY)
                                    .text_color(lb.text_secondary)
                                    .child(profile::duration(window.seconds)),
                            ),
                    );
                }
            }
            sections.push(
                profile::section(Ico::Clock, lokalbot_i18n::tr("Time This Week"), content, cx)
                    .into_any_element(),
            );
        }
        if !project.people.is_empty() {
            let people = h_flex()
                .flex_wrap()
                .gap(px(14.))
                .children(project.people.iter().map(|name| {
                    let data = self.data.clone();
                    let target = lokalbot_core::people::person_id_for_name(name);
                    profile::link(
                        SharedString::from(format!("project-person-{name}")),
                        name.clone(),
                        move |_, cx| {
                            let target = target.clone();
                            data.update(cx, |data, cx| data.open_person(target, cx));
                        },
                        cx,
                    )
                    .text_size(ty::BODY)
                }));
            sections.push(
                profile::section(Ico::Users, lokalbot_i18n::tr("People"), people, cx)
                    .into_any_element(),
            );
        }
        let meetings: AnyElement = if project.meetings.is_empty() {
            profile::empty_row(
                lokalbot_i18n::format(
                    "No meeting in the last {LOOKBACK_DAYS} days names this project.",
                    &[("LOOKBACK_DAYS", format!("{}", LOOKBACK_DAYS))],
                ),
                cx,
            )
            .into_any_element()
        } else {
            let rows: Vec<AnyElement> = project
                .meetings
                .iter()
                .take(20)
                .map(|meeting| {
                    let page = page.clone();
                    let id = meeting.id;
                    let mention = project
                        .mentions
                        .iter()
                        .find(|m| m.meeting_id == id)
                        .cloned();
                    h_flex()
                        .id(SharedString::from(format!("project-meeting-{id}")))
                        .gap(px(10.))
                        .items_start()
                        .py(px(8.))
                        .cursor_pointer()
                        .child(
                            v_flex()
                                .flex_1()
                                .min_w_0()
                                .gap(px(2.))
                                .child(
                                    div()
                                        .truncate()
                                        .text_size(ty::BODY)
                                        .text_color(lb.text)
                                        .child(meeting.title.clone()),
                                )
                                .when_some(mention.clone(), |this, mention| {
                                    this.child(
                                        div()
                                            .text_size(ty::SECONDARY)
                                            .text_color(lb.text_secondary)
                                            .line_clamp(2)
                                            .child(mention.text),
                                    )
                                }),
                        )
                        .child(
                            div()
                                .flex_none()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(profile::short_date(meeting.started_at)),
                        )
                        .on_click(move |_, _, cx| {
                            let at = mention.as_ref().and_then(|m| m.seek);
                            page.update(cx, |page, cx| page.open_meeting(id, at, cx))
                        })
                        .into_any_element()
                })
                .collect();
            profile::divided(rows, cx).into_any_element()
        };
        sections.push(
            profile::section(Ico::AudioLines, lokalbot_i18n::tr("Meetings"), meetings, cx)
                .into_any_element(),
        );
        sections.push(
            div()
                .text_size(ty::SECONDARY)
                .text_color(lb.text_secondary)
                .child(if project.is_tracked() {
                    lokalbot_i18n::tr("Linked on this PC wherever one of the project's names appears in meeting titles, summaries, transcripts, actions, decisions, and window titles.")
                } else {
                    lokalbot_i18n::tr("Suggested because the name recurs in meeting titles, summaries, actions, and decisions. People, apps, and generic terms are left out.")
                })
                .into_any_element(),
        );

        div()
            .id("project-detail")
            .size_full()
            .overflow_y_scroll()
            .track_scroll(&self.detail_scroll)
            .child(
                v_flex()
                    .w_full()
                    .max_w(metric::CONTENT_MAX_WIDTH)
                    .p(metric::DETAIL_PADDING)
                    .gap(metric::SECTION_SPACING)
                    .children(sections),
            )
            .into_any_element()
    }

    /// "Where It Stands": the written note, or how to get one.
    fn render_note(&self, project: &ProjectProfile, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let running = self
            .data
            .read(cx)
            .project_notes_running
            .contains(&project.id);
        let mut content = v_flex().gap(px(10.));
        match &project.summary {
            _ if running => content = content.child(profile::empty_row(lokalbot_i18n::tr("Writing a note from the latest meetings and review notes…"), cx)),
            None if project.meetings.is_empty() => {
                content = content.child(profile::empty_row(
                    lokalbot_i18n::tr("Nothing names this project yet. A note can be written once meetings or overnight reviews mention it."),
                    cx,
                ))
            }
            None => content = content.child(profile::empty_row(lokalbot_i18n::tr("No note yet. LokalBot can write one from the meetings and review notes below."), cx)),
            Some(summary) => {
                content = content.child(div().text_size(ty::BODY).line_height(px(21.)).text_color(lb.text).child(summary.overview.clone()));
                for (index, point) in summary.points.iter().enumerate() {
                    let page = cx.entity();
                    let meeting = point.meeting_id.as_deref().and_then(|id| Uuid::parse_str(id).ok());
                    let source = match (&point.meeting_title, &point.meeting_date) {
                        (Some(title), Some(date)) => Some(lokalbot_i18n::format("{title} · {date}", &[("title", title.to_string()), ("date", date.to_string())])),
                        (Some(title), None) => Some(title.clone()),
                        _ => None,
                    };
                    content = content.child(
                        h_flex()
                            .gap(px(8.))
                            .items_start()
                            .child(div().text_color(lb.text_secondary).child("•"))
                            .child(
                                v_flex()
                                    .flex_1()
                                    .min_w_0()
                                    .gap(px(2.))
                                    .child(div().text_size(ty::BODY).text_color(lb.text).child(point.text.clone()))
                                    .when_some(source.zip(meeting), |this, (source, meeting)| {
                                        this.child(profile::link(("project-point", index), source, move |_, cx| {
                                            page.update(cx, |page, cx| page.open_meeting(meeting, None, cx))
                                        }, cx))
                                    }),
                            ),
                    );
                }
                if !summary.open_questions.is_empty() {
                    content = content.child(div().pt(px(2.)).text_size(ty::SECONDARY).font_weight(FontWeight::SEMIBOLD).text_color(lb.text).child(crate::ui::text::paragraph(lokalbot_i18n::tr("Open questions"))));
                    for question in &summary.open_questions {
                        content = content.child(
                            h_flex()
                                .gap(px(8.))
                                .items_start()
                                .child(div().text_color(lb.text_secondary).child("?"))
                                .child(div().flex_1().min_w_0().text_size(ty::BODY).text_color(lb.text).child(question.clone())),
                        );
                    }
                }
                let stale = project.meetings.iter().any(|m| m.started_at > summary.generated_at);
                let location = summary.location.trim();
                let place = if location.is_empty() {
                    lokalbot_i18n::tr("on this PC").to_string()
                } else {
                    lokalbot_i18n::format("on {location}", &[("location", location.strip_prefix("on ").unwrap_or(location).to_string())])
                };
                if stale {
                    content = content.child(div().text_size(ty::SECONDARY).text_color(lb.text_secondary).child(crate::ui::text::paragraph(lokalbot_i18n::tr("Newer evidence since this was written."))));
                }
                let written = lokalbot_i18n::format("Written {date} by {model} {place}. Check the meetings before relying on it.", &[("date", written_when(summary.generated_at)), ("model", if summary.engine_name.is_empty() { lokalbot_i18n::tr("the Think model").to_string() } else { summary.engine_name.clone() }), ("place", place)]);
                content = content.child(div().text_size(ty::SECONDARY).text_color(lb.text_secondary).child(written));
            }
        }
        let data = self.data.clone();
        let id = project.id.clone();
        content = content.child(
            h_flex().child(
                Button::new("project-write-note")
                    .outline()
                    .small()
                    .label(if project.summary.is_none() {
                        lokalbot_i18n::tr("Write Note")
                    } else {
                        lokalbot_i18n::tr("Update")
                    })
                    .disabled(running || project.meetings.is_empty())
                    .on_click(move |_, _, cx| {
                        data.update(cx, |data, cx| {
                            data.request(AppEvent::WriteProjectNote(id.clone()), cx)
                        })
                    }),
            ),
        );
        profile::section(
            Ico::FileText,
            lokalbot_i18n::tr("Where It Stands"),
            content,
            cx,
        )
        .into_any_element()
    }
}

fn project_menu(
    menu: gpui_kit::component::menu::PopupMenu,
    page: &Entity<ProjectsPage>,
    project: &ProjectProfile,
) -> gpui_kit::component::menu::PopupMenu {
    let page = page.clone();
    if let Some(id) = project.tracked_id() {
        let rename_page = page.clone();
        let stop_page = page.clone();
        let (name, others) = (project.name.clone(), project.other_names.clone());
        menu.item(PopupMenuItem::new(lokalbot_i18n::tr("Rename…")).on_click(
            move |_, window, cx| {
                let editing = Some((id, name.clone(), others.clone()));
                rename_page.update(cx, |page, cx| page.open_name_sheet(editing, window, cx))
            },
        ))
        .separator()
        .item(
            PopupMenuItem::new(lokalbot_i18n::tr("Stop Tracking")).on_click(move |_, _, cx| {
                stop_page.update(cx, |page, cx| page.stop_tracking(id, cx))
            }),
        )
    } else {
        let track_page = page.clone();
        let hide_page = page.clone();
        let (track_name, hide_name) = (project.name.clone(), project.name.clone());
        menu.item(
            PopupMenuItem::new(lokalbot_i18n::format(
                "Track {0}",
                &[("0", project.name.to_string())],
            ))
            .on_click(move |_, _, cx| {
                let name = track_name.clone();
                track_page.update(cx, |page, cx| page.track(&name, Vec::new(), cx))
            }),
        )
        .separator()
        .item(
            PopupMenuItem::new(lokalbot_i18n::tr("Not a Project")).on_click(move |_, _, cx| {
                let name = hide_name.clone();
                hide_page.update(cx, |page, cx| page.hide_suggestion(&name, cx))
            }),
        )
    }
}

fn value_row(label: &str, value: String, color: gpui_kit::Hsla, cx: &App) -> gpui_kit::Div {
    let lb = cx.lb();
    h_flex()
        .gap(px(10.))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .text_size(ty::BODY)
                .text_color(color)
                .child(label.to_string()),
        )
        .child(
            div()
                .text_size(ty::BODY)
                .text_color(lb.text_secondary)
                .child(value),
        )
}

/// "19 meetings · 1 yours · 3h 10m this week · last yesterday" (`ProjectDetailView.summary`).
fn summary(project: &ProjectProfile, long: bool) -> String {
    let meetings = profile::count(project.meetings.len(), "meeting");
    let mut parts: Vec<String> = Vec::new();
    if project.is_tracked() {
        if !project.meetings.is_empty() {
            parts.push(meetings);
        }
    } else {
        parts.push(lokalbot_i18n::format(
            "Came up in {meetings}",
            &[("meetings", meetings.to_string())],
        ));
    }
    if !project.my_actions.is_empty() {
        parts.push(lokalbot_i18n::format(
            "{0} yours",
            &[("0", format!("{}", project.my_actions.len()))],
        ));
    }
    if long && !project.others_actions.is_empty() {
        parts.push(lokalbot_i18n::format(
            "{0} waiting on others",
            &[("0", format!("{}", project.others_actions.len()))],
        ));
    }
    if long && !project.decisions.is_empty() {
        parts.push(profile::count(project.decisions.len(), "decision"));
    }
    if project.week_seconds >= 60. {
        parts.push(lokalbot_i18n::format(
            "{0} this week",
            &[("0", profile::duration(project.week_seconds).to_string())],
        ));
    }
    if let Some(last) = project.last_active {
        parts.push(lokalbot_i18n::format(
            "last {date}",
            &[("date", profile::relative_day(last, Local::now()))],
        ));
    }
    if parts.is_empty() {
        lokalbot_i18n::tr("Nothing linked yet").into()
    } else {
        parts.join(" · ")
    }
}

fn written_when(at: chrono::DateTime<Utc>) -> String {
    let minutes = (Utc::now() - at).num_minutes();
    if minutes < 2 {
        lokalbot_i18n::tr("just now").into()
    } else if minutes < 60 {
        lokalbot_i18n::format(
            "{minutes} minutes ago",
            &[("minutes", format!("{}", minutes))],
        )
    } else {
        lokalbot_i18n::format("on {date}", &[("date", profile::short_date(at))])
    }
}

fn clean_other_names(names: &[String], excluding: &str) -> Vec<String> {
    let excluded = lokalbot_core::people::normalized(excluding);
    let mut seen = std::collections::HashSet::new();
    names
        .iter()
        .map(|n| n.split_whitespace().collect::<Vec<_>>().join(" "))
        .filter(|n| !n.is_empty())
        .filter(|n| {
            let key = lokalbot_core::people::normalized(n);
            key != excluded && seen.insert(key)
        })
        .collect()
}

impl Page for ProjectsPage {
    fn title(&self, _cx: &App) -> SharedString {
        lokalbot_i18n::tr("Projects").into()
    }
}

impl Render for ProjectsPage {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let detail = match self.selected_project().cloned() {
            Some(project) => self.render_detail(&project, cx),
            None => div()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .text_size(ty::BODY)
                .text_color(lb.text_secondary)
                .child(if self.loaded {
                    lokalbot_i18n::tr("Select a project.")
                } else {
                    lokalbot_i18n::tr("Loading projects…")
                })
                .into_any_element(),
        };
        h_flex()
            .size_full()
            .bg(lb.window)
            .child(self.render_list(cx))
            .child(div().flex_1().min_w_0().h_full().child(detail))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn other_names_are_cleaned() {
        let names = vec![
            "  Atlas ".to_string(),
            "atlas".to_string(),
            "Orion".to_string(),
            "Project X".to_string(),
        ];
        assert_eq!(
            clean_other_names(&names, "Project X"),
            vec!["Atlas".to_string(), "Orion".to_string()]
        );
    }
}
