//! The Actions workspace behind "Review Actions…" (`ActionsWorkspaceView.swift`):
//! every action of yours with status, search and sort, and an inspector.

use crate::i18n::h_flex;
use chrono::Local;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, AppContext as _, Context, Entity, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, Render, StatefulInteractiveElement as _, Styled as _, Subscription, Window,
    div, px,
};
use lokalbot_core::{ActionReference, ActionStatus};

use super::threads::open_meeting;
use crate::pages::meetings::model::{self as meeting_model, Speakers};
use crate::state::AppData;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico, action_row, segmented_tabs};

const STATUS_LABELS: [&str; 4] = ["All", "Open", "Done", "Deferred"];

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

pub(crate) struct ActionsWorkspace {
    data: Entity<AppData>,
    search: Entity<InputState>,
    query: String,
    status: Option<ActionStatus>,
    sort: Sort,
    all: Vec<ActionReference>,
    loaded: bool,
    selected: Option<String>,
    _subscriptions: Vec<Subscription>,
}

impl ActionsWorkspace {
    pub(crate) fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
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
            cx.observe_in(&data, window, |this, _, window, cx| {
                if this.loaded {
                    this.reload(window, cx);
                }
            }),
        ];
        Self {
            data,
            search,
            query: String::new(),
            status: Some(ActionStatus::Open),
            sort: Sort::Due,
            all: Vec::new(),
            loaded: false,
            selected: None,
            _subscriptions: subscriptions,
        }
    }

    pub(crate) fn reload(&mut self, _window: &mut Window, cx: &mut Context<Self>) {
        let library = self.data.read(cx).library.clone();
        cx.spawn(async move |this, cx| {
            let all = cx
                .background_spawn(async move {
                    library
                        .action_references(None)
                        .unwrap_or_default()
                        .into_iter()
                        .filter(|r| r.is_for_user)
                        .collect::<Vec<_>>()
                })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.all = all;
                this.loaded = true;
                cx.notify();
            });
        })
        .detach();
    }

    fn visible(&self) -> Vec<&ActionReference> {
        let mut visible: Vec<&ActionReference> = self
            .all
            .iter()
            .filter(|r| self.status.is_none_or(|s| r.status == s))
            .filter(|r| {
                self.query.is_empty()
                    || r.text.to_lowercase().contains(&self.query)
                    || r.meeting_title.to_lowercase().contains(&self.query)
                    || r.due
                        .as_deref()
                        .is_some_and(|d| d.to_lowercase().contains(&self.query))
            })
            .collect();
        match self.sort {
            Sort::Recent => visible.sort_by(|a, b| {
                b.meeting_started_at
                    .cmp(&a.meeting_started_at)
                    .then(a.id.cmp(&b.id))
            }),
            Sort::Due | Sort::LatestDue => {
                let descending = self.sort == Sort::LatestDue;
                visible.sort_by(|a, b| {
                    let order = match (a.resolved_due_date, b.resolved_due_date) {
                        (Some(x), Some(y)) => {
                            if descending {
                                y.cmp(&x)
                            } else {
                                x.cmp(&y)
                            }
                        }
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

    fn open_correction(
        &mut self,
        reference: &ActionReference,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let Some(meeting) = self.data.read(cx).meeting(reference.meeting_id).cloned() else {
            return;
        };
        let action = meeting_model::meeting_action(reference.clone(), &Speakers::default());
        crate::pages::meetings::dialogs::CorrectionSheet::open(
            self.data.clone(),
            meeting,
            action,
            &[],
            window,
            cx,
        );
    }

    fn back(&mut self, cx: &mut Context<Self>) {
        cx.emit(BackToToday);
    }

    // --------------------------------------------------------------- render

    fn render_header(&self, visible: usize, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        h_flex()
            .px(px(20.))
            .pt(px(12.))
            .pb(px(10.))
            .gap(px(12.))
            .items_center()
            .child(
                Button::new("actions-back")
                    .ghost()
                    .icon(Icon::new(Ico::ChevronLeft))
                    .label(lokalbot_i18n::tr("Today"))
                    .on_click(cx.listener(|this, _, _, cx| this.back(cx))),
            )
            .child(
                div()
                    .text_size(ty::COLUMN_TITLE)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Actions"))),
            )
            .child(
                div()
                    .text_size(ty::BODY)
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                        "{visible} of {0}",
                        &[
                            ("visible", format!("{}", visible)),
                            ("0", format!("{}", self.all.len())),
                        ],
                    ))),
            )
    }

    fn render_filters(&self, cx: &mut Context<Self>) -> impl IntoElement {
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
        let sort = self.sort;
        let page = cx.entity().downgrade();
        h_flex()
            .px(px(20.))
            .pb(px(12.))
            .gap(px(10.))
            .items_center()
            .flex_wrap()
            .child(
                div()
                    .w(px(300.))
                    .child(Input::new(&self.search).small().cleanable(true)),
            )
            .child(segmented_tabs::segmented_tabs(
                "actions-status",
                &STATUS_LABELS,
                status_index,
                px(74.),
                move |ix, window, cx| on_status(&ix, window, cx),
                cx,
            ))
            .child(
                Button::new("actions-sort")
                    .outline()
                    .small()
                    .icon(Icon::new(Ico::ArrowUpDown))
                    .label(lokalbot_i18n::tr(sort.label()))
                    .dropdown_caret(true)
                    .dropdown_menu(move |menu, _, _| {
                        let mut menu = menu;
                        for option in [Sort::Due, Sort::LatestDue, Sort::Recent] {
                            let page = page.clone();
                            menu = menu.item(
                                PopupMenuItem::new(lokalbot_i18n::tr(option.label()))
                                    .checked(option == sort)
                                    .on_click(move |_, _, cx| {
                                        let _ = page.update(cx, |this, cx| {
                                            this.sort = option;
                                            cx.notify();
                                        });
                                    }),
                            );
                        }
                        menu
                    }),
            )
    }

    fn render_row(
        &self,
        ix: usize,
        reference: &ActionReference,
        columns: Columns,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let today = Local::now().date_naive();
        let selected = self.selected.as_deref() == Some(reference.id.as_str());
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
        let overdue = reference.is_overdue(today);
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
            action_row::options_menu(("actions-menu", ix), move |menu, _, _| {
                let mut menu = menu;
                for option in [
                    ActionStatus::Open,
                    ActionStatus::Done,
                    ActionStatus::Deferred,
                ] {
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
                menu.separator()
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
                                let _ = details_page.update(cx, |this, cx| {
                                    this.selected = Some(details_id.clone());
                                    cx.notify();
                                });
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
                    )
            })
        };
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
                    .text_color(if overdue {
                        lb.recording_text
                    } else {
                        lb.text_secondary
                    })
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
            .on_click(cx.listener(move |this, _, _, cx| {
                this.selected = Some(id.clone());
                cx.notify();
            }))
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
            let option = [
                ActionStatus::Open,
                ActionStatus::Done,
                ActionStatus::Deferred,
            ][*ix];
            this.set_status(&status_reference, option, cx)
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
        v_flex()
            .id("actions-inspector")
            .w(px(320.))
            .flex_none()
            .h_full()
            .border_l_1()
            .border_color(lb.separator)
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
                    .children(reference.citations.iter().enumerate().map(|(ix, citation)| {
                        let data = self.data.clone();
                        let start = citation.start;
                        v_flex()
                            .gap(px(6.))
                            .p(px(12.))
                            .rounded(metric::GROUP_RADIUS)
                            .bg(lb.group_fill)
                            .border_1()
                            .border_color(lb.group_stroke)
                            .child(div().text_size(ty::BODY).text_color(lb.text).child(format!("“{}”", citation.excerpt.trim())))
                            .child(
                                h_flex()
                                    .gap(px(10.))
                                    .items_center()
                                    .child(div().text_size(ty::SECONDARY).text_color(lb.text_secondary).child(lokalbot_core::time::stamp(start)))
                                    .child(ui::link(("inspector-passage", ix), lokalbot_i18n::tr("Show Passage in Meeting"), move |_, cx| {
                                        open_meeting(&data, meeting_id, Some(start), cx)
                                    }, cx).text_size(ty::SECONDARY)),
                            )
                    }))
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

/// Asks Today to close the workspace.
pub(crate) struct BackToToday;

impl gpui_kit::EventEmitter<BackToToday> for ActionsWorkspace {}

impl Render for ActionsWorkspace {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let visible: Vec<ActionReference> = self.visible().into_iter().cloned().collect();
        let inspected = self
            .selected
            .as_deref()
            .and_then(|id| visible.iter().find(|r| r.id == id))
            .cloned();
        let list: AnyElement = if !self.loaded {
            div().into_any_element()
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
            let rows: Vec<AnyElement> = visible
                .iter()
                .enumerate()
                .map(|(ix, r)| self.render_row(ix, r, columns, cx))
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
        v_flex()
            .size_full()
            .child(self.render_header(visible.len(), cx))
            .child(self.render_filters(cx))
            .child(div().h(px(1.)).bg(lb.separator))
            .child(
                h_flex()
                    .flex_1()
                    .min_h_0()
                    .items_start()
                    .child(list)
                    .children(inspected.map(|r| self.render_inspector(&r, cx))),
            )
    }
}
