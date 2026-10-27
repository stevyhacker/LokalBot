//! The main window: sidebar, toolbar (which doubles as the title bar) and the
//! current page. Mirrors `MainWindowView.swift`.

use crate::i18n::h_flex;
use gpui_kit::component::{TitleBar, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Entity, FontWeight, Hsla, InteractiveElement as _,
    IntoElement, MouseButton, ParentElement as _, Render, SharedString,
    StatefulInteractiveElement as _, Styled as _, Subscription, Window, WindowControlArea, div,
    img, px,
};

use crate::pages::{
    Page, agent::AgentPage, ask::AskPage, meetings::MeetingsPage, people::PeoplePage,
    projects::ProjectsPage, settings::SettingsPage, timeline::TimelinePage, today::TodayPage,
};
use crate::state::{AppData, BackgroundKind, RecordingState, Section};
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

pub struct Workspace {
    data: Entity<AppData>,
    today: Entity<TodayPage>,
    meetings: Entity<MeetingsPage>,
    timeline: Entity<TimelinePage>,
    people: Entity<PeoplePage>,
    projects: Entity<ProjectsPage>,
    ask: Entity<AskPage>,
    agent: Entity<AgentPage>,
    settings: Entity<SettingsPage>,
    _subscriptions: Vec<Subscription>,
}

impl Workspace {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let data = AppData::global(cx);
        let subscriptions = vec![cx.observe(&data, |_, _, cx| cx.notify())];
        Self {
            today: cx.new(|cx| TodayPage::new(window, cx)),
            meetings: cx.new(|cx| MeetingsPage::new(window, cx)),
            timeline: cx.new(|cx| TimelinePage::new(window, cx)),
            people: cx.new(|cx| PeoplePage::new(window, cx)),
            projects: cx.new(|cx| ProjectsPage::new(window, cx)),
            ask: cx.new(|cx| AskPage::new(window, cx)),
            agent: cx.new(|cx| AgentPage::new(window, cx)),
            settings: cx.new(|cx| SettingsPage::new(window, cx)),
            data,
            _subscriptions: subscriptions,
        }
    }

    fn page_parts(
        &mut self,
        section: Section,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> (SharedString, Option<AnyElement>, AnyElement) {
        fn parts<P: Page>(
            page: &Entity<P>,
            window: &mut Window,
            cx: &mut App,
        ) -> (SharedString, Option<AnyElement>, AnyElement) {
            let (title, toolbar) =
                page.update(cx, |page, cx| (page.title(cx), page.toolbar(window, cx)));
            (title, toolbar, page.clone().into_any_element())
        }
        match section {
            Section::Today => parts(&self.today, window, cx),
            Section::Meetings => parts(&self.meetings, window, cx),
            Section::Timeline => parts(&self.timeline, window, cx),
            Section::People => parts(&self.people, window, cx),
            Section::Projects => parts(&self.projects, window, cx),
            Section::Ask => parts(&self.ask, window, cx),
            Section::Agent => parts(&self.agent, window, cx),
            Section::Settings => parts(&self.settings, window, cx),
        }
    }

    fn render_sidebar(&self, section: Section, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let item = |id: &'static str, icon: Ico, target: Section, cx: &mut Context<Self>| {
            let selected = section == target;
            let data = self.data.clone();
            h_flex()
                .id(id)
                .mx_2()
                .px(px(10.))
                .h(metric::SIDEBAR_ROW_HEIGHT)
                .gap(px(10.))
                .items_center()
                .rounded(metric::ROW_RADIUS)
                .cursor_pointer()
                .when(selected, |this| this.bg(lb.sidebar_selection))
                .when(!selected, |this| this.hover(|style| style.bg(lb.hover)))
                .child(ui::icon(icon, px(16.), lb.accent_text))
                .child(
                    div()
                        .text_size(ty::BODY)
                        .text_color(lb.text)
                        .when(selected, |this| this.font_weight(FontWeight::MEDIUM))
                        .child(target.title()),
                )
                .on_click(cx.listener(move |_, _, _, cx| {
                    data.update(cx, |data, cx| {
                        data.meeting_focus = None;
                        data.navigate(target, cx);
                    });
                }))
        };
        let header = |title: &'static str, top: f32| {
            div()
                .px(px(20.))
                .pt(px(top))
                .pb(px(4.))
                .text_size(ty::SIDEBAR_SECTION)
                .font_weight(FontWeight::BOLD)
                .text_color(lb.text_secondary)
                .child(title)
        };

        v_flex()
            .w(metric::SIDEBAR_WIDTH)
            .flex_none()
            .h_full()
            .bg(lb.sidebar)
            .border_r_1()
            .border_color(lb.separator)
            .child(self.render_brand(cx))
            .child(
                v_flex()
                    .pt_1()
                    .gap(px(2.))
                    .child(item("sidebar-today", Ico::Sun, Section::Today, cx))
                    .child(header(lokalbot_i18n::tr("Remember"), 10.))
                    .child(item(
                        "sidebar-meetings",
                        Ico::AudioLines,
                        Section::Meetings,
                        cx,
                    ))
                    .child(item(
                        "sidebar-timeline",
                        Ico::ChartGantt,
                        Section::Timeline,
                        cx,
                    ))
                    .child(item("sidebar-people", Ico::Users, Section::People, cx))
                    .child(item("sidebar-projects", Ico::Folder, Section::Projects, cx))
                    .child(item("sidebar-ask", Ico::TextSearch, Section::Ask, cx))
                    .child(header(lokalbot_i18n::tr("Tools"), 14.))
                    .child(item("sidebar-agent", Ico::WandSparkles, Section::Agent, cx))
                    .child(item(
                        "sidebar-settings",
                        Ico::Settings,
                        Section::Settings,
                        cx,
                    )),
            )
            .child(div().flex_1())
            .child(self.render_sidebar_footer(cx))
    }

    /// The app mark at the top of the sidebar; also a window drag handle.
    fn render_brand(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        drag_region(
            h_flex()
                .id("sidebar-brand")
                .h(metric::TOOLBAR_HEIGHT)
                .px(px(18.))
                .gap(px(10.))
                .items_center()
                .flex_none()
                .child(img("brand/lokalbot.svg").size(px(26.)).flex_none())
                .child(
                    v_flex()
                        .child(
                            div()
                                .text_size(ty::BODY)
                                .font_weight(FontWeight::SEMIBOLD)
                                .text_color(lb.text)
                                .child("LokalBot"),
                        )
                        .child(
                            div()
                                .text_size(ty::SMALL)
                                .text_color(lb.text_secondary)
                                .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                    "Private work memory",
                                ))),
                        ),
                ),
        )
    }

    fn render_sidebar_footer(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let data = self.data.read(cx);
        let lb = cx.lb().clone();
        let recording = match &data.recording {
            RecordingState::Recording {
                meeting, started, ..
            } => Some((meeting.display_title(), started.elapsed().as_secs_f64())),
            _ => None,
        };
        let background = data.background.clone();
        let inference_label = data.inference_label.clone();
        let remote_hosts = data.remote_hosts.clone();
        let data_entity = self.data.clone();

        v_flex()
            .p(px(10.))
            .gap(px(10.))
            .when_some(recording, |this, (_title, elapsed)| {
                let data_entity = data_entity.clone();
                this.child(
                    ui::status_surface(lb.recording, cx)
                        .p(px(10.))
                        .child(
                            h_flex()
                                .gap(px(6.))
                                .items_center()
                                .child(ui::status_dot(lb.recording, px(8.)))
                                .child(
                                    div()
                                        .text_size(ty::SECONDARY)
                                        .font_weight(FontWeight::SEMIBOLD)
                                        .text_color(lb.recording_text)
                                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                            "Recording",
                                        ))),
                                )
                                .child(div().flex_1())
                                .child(
                                    div()
                                        .text_size(ty::SECONDARY)
                                        .text_color(lb.recording_text)
                                        .child(lokalbot_core::time::timer(elapsed)),
                                ),
                        )
                        .child(
                            div()
                                .id("sidebar-live")
                                .mt(px(6.))
                                .cursor_pointer()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.recording_text)
                                .hover(|s| s.underline())
                                .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                    "Live Meeting Notes",
                                )))
                                .on_click(move |_, _, cx| {
                                    data_entity.update(cx, |data, cx| {
                                        if let Some(meeting) = data.recording.meeting().cloned() {
                                            data.open_meeting(
                                                meeting.id,
                                                Default::default(),
                                                None,
                                                cx,
                                            );
                                        }
                                    })
                                }),
                        ),
                )
            })
            .when_some(background.first().cloned(), |this, first| {
                let more = background.len().saturating_sub(1);
                this.child(
                    ui::grouped_surface(cx)
                        .p(px(10.))
                        .child(
                            h_flex()
                                .gap(px(8.))
                                .items_center()
                                .child(ui::icon(
                                    background_icon(first.kind),
                                    px(14.),
                                    lb.accent_text,
                                ))
                                .child(
                                    div()
                                        .flex_1()
                                        .min_w_0()
                                        .truncate()
                                        .text_size(ty::SECONDARY)
                                        .font_weight(FontWeight::SEMIBOLD)
                                        .text_color(lb.text)
                                        .child(first.title.clone()),
                                ),
                        )
                        .child(
                            div()
                                .mt(px(2.))
                                .text_size(ty::CAPTION)
                                .text_color(lb.text_secondary)
                                .child(first.detail.clone()),
                        )
                        .when_some(first.progress, |this, progress| {
                            this.child(progress_line(progress, lb.accent_fill, lb.chip_fill))
                        })
                        .when(more > 0, |this| {
                            this.child(
                                div()
                                    .mt(px(4.))
                                    .text_size(ty::CAPTION)
                                    .text_color(lb.text_secondary)
                                    .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                                        "+{more} more",
                                        &[("more", format!("{}", more))],
                                    ))),
                            )
                        }),
                )
            })
            .child(
                ui::grouped_surface(cx).p(px(10.)).child(
                    h_flex()
                        .gap(px(8.))
                        .items_start()
                        .child(ui::icon(Ico::ShieldCheck, px(16.), lb.accent_text))
                        .child(
                            v_flex()
                                .gap(px(2.))
                                .child(
                                    div()
                                        .text_size(ty::SECONDARY)
                                        .font_weight(FontWeight::SEMIBOLD)
                                        .text_color(lb.text)
                                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                            "Storage: this PC",
                                        ))),
                                )
                                .child(
                                    h_flex()
                                        .gap(px(4.))
                                        .items_center()
                                        .child(
                                            div()
                                                .text_size(ty::CAPTION)
                                                .text_color(lb.supporting)
                                                .child(inference_label),
                                        )
                                        .when(!remote_hosts.is_empty(), |this| {
                                            this.child(ui::status_dot(lb.attention, px(5.)))
                                        }),
                                )
                                .children(remote_hosts.into_iter().map(|host| {
                                    div()
                                        .text_size(ty::CAPTION)
                                        .text_color(lb.supporting)
                                        .child(host)
                                })),
                        ),
                ),
            )
    }

    fn render_toolbar(
        &self,
        title: SharedString,
        toolbar: Option<AnyElement>,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        TitleBar::new()
            .h(metric::TOOLBAR_HEIGHT)
            .bg(lb.title_bar)
            .border_color(lb.separator)
            .child(
                div()
                    .pl(px(16.))
                    .text_size(ty::COLUMN_TITLE)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .child(title),
            )
            .child(
                h_flex()
                    .h_full()
                    .items_center()
                    .gap_1()
                    .pr_2()
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .children(toolbar),
            )
    }

    fn render_toast(&self, cx: &mut Context<Self>) -> Option<impl IntoElement + use<>> {
        let toast = self.data.read(cx).toast.clone()?;
        let lb = cx.lb().clone();
        let tint = if toast.is_error {
            lb.attention_text
        } else {
            lb.accent_text
        };
        let data = self.data.clone();
        Some(
            div().p(px(12.)).child(
                h_flex()
                    .gap(px(10.))
                    .items_center()
                    .px(px(14.))
                    .py(px(9.))
                    .rounded(metric::GROUP_RADIUS)
                    .bg(lb.elevated)
                    .border_1()
                    .border_color(tint.opacity(0.4))
                    .shadow_md()
                    .child(ui::icon(
                        if toast.is_error {
                            Ico::TriangleAlert
                        } else {
                            Ico::CircleCheck
                        },
                        px(16.),
                        tint,
                    ))
                    .child(
                        div()
                            .flex_1()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text)
                            .child(toast.message),
                    )
                    .child(
                        div()
                            .id("toast-dismiss")
                            .cursor_pointer()
                            .child(ui::icon(Ico::X, px(14.), lb.text_secondary))
                            .on_click(move |_, _, cx| {
                                data.update(cx, |data, cx| data.dismiss_toast(cx))
                            }),
                    ),
            ),
        )
    }
}

impl Render for Workspace {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let section = self.data.read(cx).section;
        let (title, toolbar, page) = self.page_parts(section, window, cx);
        let lb = cx.lb().clone();
        let toast = self.render_toast(cx);

        h_flex()
            .size_full()
            .bg(lb.window)
            .text_color(lb.text)
            .font_family(crate::theme::FONT_FAMILY)
            .child(self.render_sidebar(section, cx))
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .child(self.render_toolbar(title, toolbar, cx))
                    .child(div().flex_1().min_h_0().relative().child(page))
                    .children(toast),
            )
    }
}

fn background_icon(kind: BackgroundKind) -> Ico {
    match kind {
        BackgroundKind::Meeting => Ico::AudioLines,
        BackgroundKind::Digest => Ico::FileText,
        BackgroundKind::Download => Ico::ArrowDown,
        BackgroundKind::Reindex => Ico::Search,
    }
}

fn progress_line(progress: f32, fill: Hsla, track: Hsla) -> impl IntoElement {
    div()
        .mt(px(6.))
        .h(px(4.))
        .w_full()
        .rounded_full()
        .bg(track)
        .child(
            div()
                .h_full()
                .rounded_full()
                .bg(fill)
                .w(gpui_kit::relative(progress.clamp(0.0, 1.0))),
        )
}

/// Lets an element move the window, like the title bar does.
pub fn drag_region<
    E: gpui_kit::StatefulInteractiveElement + gpui_kit::InteractiveElement + IntoElement,
>(
    element: E,
) -> E {
    let element = element.window_control_area(WindowControlArea::Drag);
    if cfg!(target_os = "linux") {
        element.on_mouse_down(MouseButton::Left, |_, window, _| window.start_window_move())
    } else {
        element
    }
}
