//! People (`PeopleWorkspaceView.swift`): everyone from your meetings, with
//! open work first, and each person's open work, notes, projects,
//! decisions and shared meetings.

use std::collections::{BTreeMap, HashSet};

use crate::i18n::h_flex;
use chrono::{Duration, Local, Utc};
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::menu::{ContextMenuExt as _, DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::popover::Popover;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Entity, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, Render, ScrollHandle, SharedString,
    StatefulInteractiveElement as _, Styled as _, Subscription, Window, div, px,
};
use lokalbot_core::{HiddenPerson, MeetingRef, PeopleCuration, PersonProfile};
use uuid::Uuid;

use crate::pages::Page;
use crate::state::{AppData, AskRequest, MeetingTab};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico, profile};

const PROVENANCE: &str = "Built on this PC from calendar attendees, names you gave speakers, action owners, and meeting notes. Email addresses are used only to tell people apart and are never shown or shared.";
const VISIBLE_SERIES: usize = 8;

pub struct PeoplePage {
    data: Entity<AppData>,
    people: Vec<PersonProfile>,
    curation: PeopleCuration,
    loaded: bool,
    loaded_revision: Option<u64>,
    selected: Option<String>,
    search: Entity<InputState>,
    query: String,
    rename_input: Entity<InputState>,
    expanded_series: HashSet<String>,
    list_scroll: ScrollHandle,
    detail_scroll: ScrollHandle,
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
            people: Vec::new(),
            curation: PeopleCuration::default(),
            loaded: false,
            loaded_revision: None,
            selected: None,
            search,
            query: String::new(),
            rename_input,
            expanded_series: HashSet::new(),
            list_scroll: ScrollHandle::new(),
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
                .background_spawn(async move { (library.people(), library.people_curation()) })
                .await;
            let _ = this.update(cx, |this, cx| {
                match loaded {
                    (Ok(people), curation) => {
                        this.people = people;
                        this.curation = curation.unwrap_or_default();
                    }
                    (Err(err), _) => log::warn!("loading people failed: {err:#}"),
                }
                this.loaded = true;
                cx.notify();
            });
        })
        .detach();
    }

    fn save_curation(&mut self, curation: PeopleCuration, cx: &mut Context<Self>) {
        self.curation = curation.clone();
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
            self.selected = None;
        }
        self.save_curation(curation, cx);
    }

    fn restore_hidden(&mut self, cx: &mut Context<Self>) {
        let mut curation = self.curation.clone();
        curation.hidden.clear();
        self.save_curation(curation, cx);
    }

    fn open_rename(&mut self, person: &PersonProfile, window: &mut Window, cx: &mut Context<Self>) {
        let name = person.name.clone();
        self.rename_input
            .update(cx, |input, cx| input.set_value(name.clone(), window, cx));
        let page = cx.entity();
        let input = self.rename_input.clone();
        let person_id = person.id.clone();
        let members = person.member_ids.clone();
        window.open_dialog(cx, move |dialog, _, cx| {
            let lb = cx.lb().clone();
            let save_page = page.clone();
            let reset_page = page.clone();
            let save_input = input.clone();
            let (save_id, reset_id) = (person_id.clone(), person_id.clone());
            let (save_members, reset_members) = (members.clone(), members.clone());
            dialog.title(lokalbot_i18n::format("Rename {name}", &[("name", name.to_string())])).w(px(440.)).child(
                v_flex()
                    .gap(px(12.))
                    .child(Input::new(&input))
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr("People shows this name, and LokalBot also recognizes it in meeting notes and action owners. Names from your meetings stay listed as other names."))),
                    )
                    .child(
                        h_flex()
                            .gap(px(8.))
                            .pt(px(4.))
                            .child(Button::new("people-rename-reset").outline().label(lokalbot_i18n::tr("Use Name from Meetings")).on_click(
                                move |_, window, cx| {
                                    reset_page.update(cx, |page, cx| page.rename(&reset_id, &reset_members, "", cx));
                                    window.close_dialog(cx);
                                },
                            ))
                            .child(div().flex_1().min_w_0())
                            .child(Button::new("people-rename-cancel").outline().label(lokalbot_i18n::tr("Cancel")).on_click(|_, window, cx| {
                                window.close_dialog(cx)
                            }))
                            .child(Button::new("people-rename-save").primary().label(lokalbot_i18n::tr("Save")).on_click(move |_, window, cx| {
                                let value = save_input.read(cx).value().to_string();
                                save_page.update(cx, |page, cx| page.rename(&save_id, &save_members, &value, cx));
                                window.close_dialog(cx);
                            })),
                    ),
            )
        });
    }

    fn filtered(&self) -> Vec<&PersonProfile> {
        let query = self.query.trim().to_lowercase();
        let hidden: HashSet<&str> = self.curation.hidden.iter().map(|h| h.id.as_str()).collect();
        self.people
            .iter()
            .filter(|p| !hidden.contains(p.id.as_str()))
            .filter(|p| {
                query.is_empty()
                    || p.name.to_lowercase().contains(&query)
                    || p.other_names
                        .iter()
                        .any(|n| n.to_lowercase().contains(&query))
            })
            .collect()
    }

    /// Open work first, then the last two weeks by how often you met, then the rest.
    fn grouped(&self) -> Vec<(&'static str, Vec<&PersonProfile>)> {
        let now = Utc::now();
        let cutoff = now - Duration::days(14);
        let frequency_start = now - Duration::days(30);
        let people = self.filtered();
        let mut open: Vec<&PersonProfile> = people
            .iter()
            .copied()
            .filter(|p| p.open_count() > 0)
            .collect();
        open.sort_by(|a, b| {
            b.my_actions
                .is_empty()
                .cmp(&a.my_actions.is_empty())
                .reverse()
                .then(b.open_count().cmp(&a.open_count()))
                .then(b.last_met().cmp(&a.last_met()))
        });
        let rest: Vec<&PersonProfile> = people
            .iter()
            .copied()
            .filter(|p| p.open_count() == 0)
            .collect();
        let frequency = |p: &PersonProfile| {
            p.meetings
                .iter()
                .filter(|m| m.started_at >= frequency_start)
                .count()
        };
        let mut recent: Vec<&PersonProfile> = rest
            .iter()
            .copied()
            .filter(|p| p.last_met().is_some_and(|d| d >= cutoff))
            .collect();
        recent.sort_by(|a, b| {
            frequency(b)
                .cmp(&frequency(a))
                .then(b.last_met().cmp(&a.last_met()))
                .then(a.name.cmp(&b.name))
        });
        let mut earlier: Vec<&PersonProfile> = rest
            .iter()
            .copied()
            .filter(|p| !p.last_met().is_some_and(|d| d >= cutoff))
            .collect();
        earlier.sort_by_key(|p| std::cmp::Reverse(p.last_met()));
        [
            (lokalbot_i18n::tr("Open Work"), open),
            (lokalbot_i18n::tr("Last 2 Weeks"), recent),
            (lokalbot_i18n::tr("Earlier"), earlier),
        ]
        .into_iter()
        .filter(|(_, items)| !items.is_empty())
        .collect()
    }

    /// Selects a person another page asked to show.
    fn take_focus(&mut self, cx: &mut Context<Self>) {
        if let Some(id) = self.data.update(cx, |data, _| data.person_focus.take()) {
            self.selected = Some(id);
            self.detail_scroll
                .set_offset(gpui_kit::point(px(0.), px(0.)));
        }
    }

    fn selected_person(&self) -> Option<&PersonProfile> {
        match &self.selected {
            Some(id) => self
                .people
                .iter()
                .find(|p| &p.id == id || p.member_ids.contains(id)),
            None => self
                .grouped()
                .first()
                .and_then(|(_, people)| people.first().copied()),
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
        let count = self.filtered().len();
        let summary = if self.loaded {
            lokalbot_i18n::format(
                "{people} from your meetings",
                &[("people", lokalbot_i18n::count(count, "person"))],
            )
        } else {
            lokalbot_i18n::tr("Loading…").into()
        };
        let selected_id = self.selected_person().map(|p| p.id.clone());
        let mut rows: Vec<AnyElement> = Vec::new();
        for (title, people) in self.grouped() {
            rows.push(
                div()
                    .px(px(18.))
                    .pt(px(10.))
                    .pb(px(4.))
                    .text_size(ty::SECONDARY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.supporting)
                    .child(title)
                    .into_any_element(),
            );
            for person in people {
                rows.push(self.render_row(
                    person,
                    selected_id.as_deref() == Some(person.id.as_str()),
                    cx,
                ));
            }
        }
        if !self.curation.hidden.is_empty() {
            let hidden = self.curation.hidden.len();
            let label = lokalbot_i18n::format(
                "Show hidden entries ({count})",
                &[("count", hidden.to_string())],
            );
            let page = cx.entity();
            rows.push(
                div()
                    .px(px(18.))
                    .py(px(8.))
                    .child(profile::link(
                        "people-restore-hidden",
                        label,
                        move |_, cx| page.update(cx, |page, cx| page.restore_hidden(cx)),
                        cx,
                    ))
                    .into_any_element(),
            );
        }
        if self.loaded && self.people.is_empty() {
            rows.push(
                div()
                    .p(px(24.))
                    .text_center()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr("People appear after meetings with calendar attendees, named speakers, or named action owners.")))
                    .into_any_element(),
            );
        }
        v_flex()
            .w(metric::CONTENT_COLUMN_WIDTH)
            .flex_none()
            .h_full()
            .border_r_1()
            .border_color(lb.separator)
            .child(
                v_flex()
                    .gap(px(10.))
                    .p(metric::PANEL_PADDING)
                    .child(
                        h_flex()
                            .gap(px(4.))
                            .items_center()
                            .child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.text_secondary)
                                    .child(summary),
                            )
                            .child(
                                Popover::new("people-provenance")
                                    .trigger(
                                        Button::new("people-info")
                                            .ghost()
                                            .xsmall()
                                            .icon(Icon::new(Ico::Info))
                                            .tooltip(lokalbot_i18n::tr("Where People comes from")),
                                    )
                                    .content(|_, _, cx| {
                                        div()
                                            .w(px(300.))
                                            .text_size(ty::SECONDARY)
                                            .text_color(cx.lb().text)
                                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                                PROVENANCE,
                                            )))
                                    }),
                            ),
                    )
                    .child(Input::new(&self.search).cleanable(true).prefix(ui::icon(
                        Ico::Search,
                        px(14.),
                        lb.text_secondary,
                    ))),
            )
            .child(
                div()
                    .id("people-list")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .track_scroll(&self.list_scroll)
                    .pb(px(12.))
                    .children(rows),
            )
    }

    fn render_row(
        &self,
        person: &PersonProfile,
        selected: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let id = person.id.clone();
        let tint = profile::name_tint(&person.name, cx);
        let context = row_context(person);
        let page = cx.entity();
        let menu_person = person.clone();
        h_flex()
            .id(SharedString::from(format!("person-{}", person.id)))
            .mx(px(8.))
            .px(px(10.))
            .py(px(7.))
            .gap(px(10.))
            .items_center()
            .rounded(metric::ROW_RADIUS)
            .cursor_pointer()
            .when(selected, |this| this.bg(lb.sidebar_selection))
            .when(!selected, |this| this.hover(|s| s.bg(lb.hover)))
            .child(ui::avatar(profile::initials(&person.name), tint, px(30.)))
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(2.))
                    .child(
                        h_flex()
                            .gap(px(6.))
                            .items_center()
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .truncate()
                                    .text_size(ty::BODY)
                                    .font_weight(FontWeight::MEDIUM)
                                    .text_color(lb.text)
                                    .child(person.name.clone()),
                            )
                            .when_some(person.last_met(), |this, last| {
                                this.child(
                                    div()
                                        .flex_none()
                                        .text_size(ty::CAPTION)
                                        .text_color(lb.text_secondary)
                                        .child(profile::relative_day(last, Local::now())),
                                )
                            }),
                    )
                    .child(
                        h_flex()
                            .gap(px(6.))
                            .items_center()
                            .child(
                                div()
                                    .flex_1()
                                    .min_w_0()
                                    .truncate()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.text_secondary)
                                    .child(context),
                            )
                            .children(profile::open_work_pills(
                                person.my_actions.len(),
                                person.their_actions.len(),
                                cx,
                            )),
                    ),
            )
            .on_click(cx.listener(move |this, _, _, cx| {
                this.selected = Some(id.clone());
                this.detail_scroll
                    .set_offset(gpui_kit::point(px(0.), px(0.)));
                cx.notify();
            }))
            .context_menu(move |menu, _, _| {
                let rename_page = page.clone();
                let hide_page = page.clone();
                let rename_person = menu_person.clone();
                let hide_person = menu_person.clone();
                menu.item(PopupMenuItem::new(lokalbot_i18n::tr("Rename…")).on_click(
                    move |_, window, cx| {
                        let person = rename_person.clone();
                        rename_page.update(cx, |page, cx| page.open_rename(&person, window, cx));
                    },
                ))
                .separator()
                .item(
                    PopupMenuItem::new(lokalbot_i18n::tr("Not a Person")).on_click(
                        move |_, _, cx| {
                            let person = hide_person.clone();
                            hide_page.update(cx, |page, cx| page.hide(&person, cx));
                        },
                    ),
                )
            })
            .into_any_element()
    }

    fn render_detail(&self, person: &PersonProfile, cx: &mut Context<Self>) -> AnyElement {
        let lb = cx.lb().clone();
        let first = person.first_name().to_string();
        let tint = profile::name_tint(&person.name, cx);
        let mut sections: Vec<AnyElement> = Vec::new();

        // Header.
        let ask_data = self.data.clone();
        let question = lokalbot_i18n::format(
            "What has {0} been working on lately, and what is open between us?",
            &[("0", person.name.to_string())],
        );
        let meeting_ids: Vec<Uuid> = person.meetings.iter().map(|m| m.id).collect();
        let page = cx.entity();
        let menu_person = person.clone();
        sections.push(
            v_flex()
                .gap(px(14.))
                .child(
                    h_flex()
                        .gap(px(14.))
                        .items_center()
                        .child(ui::avatar(profile::initials(&person.name), tint, px(56.)))
                        .child(
                            v_flex()
                                .flex_1()
                                .min_w_0()
                                .gap(px(4.))
                                .child(
                                    div()
                                        .text_size(ty::PAGE_TITLE)
                                        .font_weight(FontWeight::BOLD)
                                        .text_color(lb.text)
                                        .child(person.name.clone()),
                                )
                                .child(
                                    div()
                                        .text_size(ty::SECONDARY)
                                        .text_color(lb.text_secondary)
                                        .child(stats(person)),
                                )
                                .when(!person.other_names.is_empty(), |this| {
                                    this.child(
                                        div()
                                            .text_size(ty::SECONDARY)
                                            .text_color(lb.text_secondary)
                                            .child(crate::ui::text::paragraph(
                                                lokalbot_i18n::format(
                                                    "Also appears as {0}",
                                                    &[(
                                                        "0",
                                                        person.other_names.join(", ").to_string(),
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
                            Button::new("person-ask")
                                .outline()
                                .icon(Icon::new(Ico::TextSearch))
                                .label(lokalbot_i18n::format(
                                    "Ask About {first}",
                                    &[("first", first.to_string())],
                                ))
                                .disabled(person.meetings.is_empty())
                                .on_click(move |_, _, cx| {
                                    let request = AskRequest {
                                        question: question.clone(),
                                        meeting_ids: meeting_ids.clone(),
                                        submit: false,
                                    };
                                    ask_data.update(cx, |data, cx| data.ask(request, cx));
                                }),
                        )
                        .child(
                            Button::new("person-more")
                                .ghost()
                                .icon(Icon::new(Ico::Ellipsis))
                                .label(lokalbot_i18n::tr("More"))
                                .dropdown_menu(move |menu, _, _| {
                                    let rename_page = page.clone();
                                    let hide_page = page.clone();
                                    let rename_person = menu_person.clone();
                                    let hide_person = menu_person.clone();
                                    menu.item(
                                        PopupMenuItem::new(lokalbot_i18n::tr("Rename…")).on_click(
                                            move |_, window, cx| {
                                                let person = rename_person.clone();
                                                rename_page.update(cx, |page, cx| {
                                                    page.open_rename(&person, window, cx)
                                                });
                                            },
                                        ),
                                    )
                                    .separator()
                                    .item(
                                        PopupMenuItem::new(lokalbot_i18n::tr("Not a Person"))
                                            .on_click(move |_, _, cx| {
                                                let person = hide_person.clone();
                                                hide_page
                                                    .update(cx, |page, cx| page.hide(&person, cx));
                                            }),
                                    )
                                }),
                        ),
                )
                .into_any_element(),
        );

        // Open work.
        let page = cx.entity();
        let thread_rows =
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
        if person.my_actions.is_empty() && person.their_actions.is_empty() {
            sections.push(
                profile::section(
                    Ico::ListChecks,
                    lokalbot_i18n::tr("Open Work"),
                    profile::empty_row(
                        lokalbot_i18n::format(
                            "Nothing open between you and {first}.",
                            &[("first", first.to_string())],
                        ),
                        cx,
                    ),
                    cx,
                )
                .into_any_element(),
            );
        } else {
            if !person.my_actions.is_empty() {
                let rows = thread_rows(&person.my_actions, "mine", cx);
                sections.push(
                    profile::section(
                        Ico::ArrowUpRight,
                        lokalbot_i18n::tr("Waiting on You"),
                        rows,
                        cx,
                    )
                    .into_any_element(),
                );
            }
            if !person.their_actions.is_empty() {
                let rows = thread_rows(&person.their_actions, "theirs", cx);
                sections.push(
                    profile::section(
                        Ico::ArrowDownLeft,
                        lokalbot_i18n::format(
                            "Waiting on {first}",
                            &[("first", first.to_string())],
                        ),
                        rows,
                        cx,
                    )
                    .into_any_element(),
                );
            }
        }

        // Last time.
        if !person.recent_notes.is_empty() {
            let latest = person.meetings.iter().map(|m| m.id).next();
            let title = match (&person.notes_meeting, latest) {
                (Some(meeting), Some(latest)) if meeting.id == latest => {
                    lokalbot_i18n::tr("Last Time")
                }
                (Some(_), _) => lokalbot_i18n::tr("Last Mentioned"),
                _ => lokalbot_i18n::tr("Last Time"),
            };
            let mut content = v_flex().gap(px(8.));
            if let Some(meeting) = person.notes_meeting.clone() {
                let page = page.clone();
                content = content.child(profile::link(
                    "person-notes-meeting",
                    format!(
                        "{} · {}",
                        meeting.title,
                        profile::short_date(meeting.started_at)
                    ),
                    move |_, cx| {
                        page.update(cx, |page, cx| page.open_meeting(meeting.id, None, cx))
                    },
                    cx,
                ));
            }
            for note in &person.recent_notes {
                content = content.child(
                    h_flex()
                        .gap(px(8.))
                        .items_start()
                        .child(div().text_color(lb.text_secondary).child("•"))
                        .child(
                            div()
                                .flex_1()
                                .min_w_0()
                                .text_size(ty::BODY)
                                .text_color(lb.text)
                                .child(note.clone()),
                        ),
                );
            }
            sections.push(profile::section(Ico::Quote, title, content, cx).into_any_element());
        }

        // Projects.
        if !person.project_links.is_empty() {
            let links =
                h_flex()
                    .flex_wrap()
                    .gap(px(14.))
                    .children(person.project_links.iter().map(|link| {
                        let label = if link.is_tracked {
                            link.name.clone()
                        } else {
                            lokalbot_i18n::format(
                                "{0} (suggested)",
                                &[("0", link.name.to_string())],
                            )
                        };
                        let target = link.id.clone();
                        let data = self.data.clone();
                        profile::link(
                            SharedString::from(format!("person-project-{}", link.id)),
                            label,
                            move |_, cx| {
                                let target = target.clone();
                                data.update(cx, |data, cx| data.open_project(target, cx));
                            },
                            cx,
                        )
                        .text_size(ty::BODY)
                    }));
            sections.push(
                profile::section(Ico::Folder, lokalbot_i18n::tr("Projects"), links, cx)
                    .into_any_element(),
            );
        }

        // Decisions.
        if !person.decisions.is_empty() {
            let rows: Vec<AnyElement> = person
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
                            ("person-decision", index),
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
                    lokalbot_i18n::tr("Decisions Together"),
                    profile::divided(rows, cx),
                    cx,
                )
                .into_any_element(),
            );
        }

        // Meetings together, as series by title.
        let series = series(&person.meetings);
        let meetings_content: AnyElement = if series.is_empty() {
            profile::empty_row(
                lokalbot_i18n::format(
                    "{first} appears only as an action owner.",
                    &[("first", first.to_string())],
                ),
                cx,
            )
            .into_any_element()
        } else {
            let mut rows: Vec<AnyElement> = Vec::new();
            for (title, meetings) in series.iter().take(VISIBLE_SERIES) {
                rows.push(self.render_series(title, meetings, cx));
            }
            let mut column = v_flex().child(profile::divided(rows, cx));
            if series.len() > VISIBLE_SERIES {
                let rest = &series[VISIBLE_SERIES..];
                let count: usize = rest.iter().map(|(_, m)| m.len()).sum();
                column = column.child(
                    div()
                        .pt(px(8.))
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                            "{meetings}; other titles: {titles}.",
                            &[
                                ("meetings", profile::count(count, "more meeting")),
                                ("titles", rest.len().to_string()),
                            ],
                        ))),
                );
            }
            column.into_any_element()
        };
        sections.push(
            profile::section(
                Ico::AudioLines,
                lokalbot_i18n::tr("Meetings Together"),
                meetings_content,
                cx,
            )
            .into_any_element(),
        );

        div()
            .id("person-detail")
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

    fn render_series(
        &self,
        title: &str,
        meetings: &[MeetingRef],
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let latest = meetings[0].clone();
        let key = format!("{title}-{}", latest.id);
        let expanded = self.expanded_series.contains(&key);
        let recurring = meetings.len() > 1;
        let page = cx.entity();
        let toggle_key = key.clone();
        let row = h_flex()
            .id(SharedString::from(format!("series-{key}")))
            .gap(px(10.))
            .items_center()
            .py(px(8.))
            .cursor_pointer()
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .truncate()
                    .text_size(ty::BODY)
                    .text_color(lb.text)
                    .child(title.to_string()),
            )
            .when(recurring, |this| {
                this.child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(profile::count(meetings.len(), "meeting")),
                )
            })
            .child(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(profile::short_date(latest.started_at)),
            )
            .child(ui::icon(
                if recurring && expanded {
                    Ico::ChevronDown
                } else {
                    Ico::ChevronRight
                },
                px(12.),
                lb.text_tertiary,
            ))
            .on_click(move |_, _, cx| {
                let key = toggle_key.clone();
                page.update(cx, |page, cx| {
                    if recurring {
                        if !page.expanded_series.remove(&key) {
                            page.expanded_series.insert(key);
                        }
                        cx.notify();
                    } else {
                        page.open_meeting(latest.id, None, cx);
                    }
                })
            });
        if !(recurring && expanded) {
            return row.into_any_element();
        }
        let page = cx.entity();
        v_flex()
            .child(row)
            .children(meetings.iter().map(|meeting| {
                let page = page.clone();
                let id = meeting.id;
                h_flex()
                    .id(SharedString::from(format!("series-item-{}", meeting.id)))
                    .pl(px(16.))
                    .py(px(5.))
                    .gap(px(10.))
                    .cursor_pointer()
                    .hover(|s| s.bg(lb.hover))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text)
                            .child(
                                meeting
                                    .started_at
                                    .with_timezone(&Local)
                                    .format_localized(
                                        lokalbot_i18n::date_pattern("%A, %B %-d"),
                                        lokalbot_i18n::date_locale(),
                                    )
                                    .to_string(),
                            ),
                    )
                    .child(ui::icon(Ico::ChevronRight, px(12.), lb.text_tertiary))
                    .on_click(move |_, _, cx| {
                        page.update(cx, |page, cx| page.open_meeting(id, None, cx))
                    })
            }))
            .into_any_element()
    }
}

/// What sets this person apart: projects named around them, else the
/// meetings you share most, else how many meetings.
fn row_context(person: &PersonProfile) -> String {
    let projects: Vec<&str> = person
        .project_links
        .iter()
        .take(2)
        .map(|p| p.name.as_str())
        .collect();
    if !projects.is_empty() {
        return projects.join(" · ");
    }
    let mut series = series(&person.meetings);
    series.sort_by_key(|(_, meetings)| std::cmp::Reverse(meetings.len()));
    let titles: Vec<&str> = series.iter().take(2).map(|(t, _)| t.as_str()).collect();
    if !titles.is_empty() {
        return titles.join(", ");
    }
    match person.meeting_count() {
        0 => lokalbot_i18n::tr("Named in actions").into(),
        n => profile::count(n, "meeting"),
    }
}

/// "12 meetings since Aug 3 · last met yesterday · 3 open".
fn stats(person: &PersonProfile) -> String {
    let count = person.meeting_count();
    let mut first = profile::count(count, "meeting");
    if count > 1
        && let Some(earliest) = person.meetings.iter().map(|m| m.started_at).min()
    {
        first = lokalbot_i18n::format(
            "{meetings} since {date}",
            &[
                ("meetings", first),
                (
                    "date",
                    earliest
                        .with_timezone(&Local)
                        .format_localized("%x", lokalbot_i18n::date_locale())
                        .to_string(),
                ),
            ],
        );
    }
    let mut parts = vec![first];
    if let Some(last) = person.last_met() {
        parts.push(lokalbot_i18n::format(
            "last met {date}",
            &[("date", profile::relative_day(last, Local::now()))],
        ));
    }
    if person.open_count() > 0 {
        parts.push(lokalbot_i18n::format(
            "{0} open",
            &[("0", format!("{}", person.open_count()))],
        ));
    }
    parts.join(" · ")
}

/// Meetings grouped by title, newest series first, each newest first.
fn series(meetings: &[MeetingRef]) -> Vec<(String, Vec<MeetingRef>)> {
    let mut by_title: BTreeMap<String, Vec<MeetingRef>> = BTreeMap::new();
    for meeting in meetings {
        by_title
            .entry(meeting.title.clone())
            .or_default()
            .push(meeting.clone());
    }
    let mut series: Vec<(String, Vec<MeetingRef>)> = by_title
        .into_iter()
        .map(|(title, mut meetings)| {
            meetings.sort_by_key(|m| std::cmp::Reverse(m.started_at));
            (title, meetings)
        })
        .collect();
    series.sort_by(|a, b| b.1[0].started_at.cmp(&a.1[0].started_at));
    series
}

impl Page for PeoplePage {
    fn title(&self, _cx: &App) -> SharedString {
        lokalbot_i18n::tr("People").into()
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
                .text_size(ty::BODY)
                .text_color(lb.text_secondary)
                .child(if self.loaded {
                    lokalbot_i18n::tr("Select a person.")
                } else {
                    lokalbot_i18n::tr("Loading people…")
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
