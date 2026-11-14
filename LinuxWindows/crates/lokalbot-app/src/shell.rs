//! The main window: sidebar, toolbar (which doubles as the title bar) and the
//! current page. Mirrors `MainWindowView.swift`: Today and Actions lead,
//! Remember and Assistant group the rest, and Settings with the privacy line
//! sits in the sidebar's foot. Settings opens its own window.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::popover::Popover;
use gpui_kit::component::{Sizable as _, TitleBar, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Context, Entity, FontWeight, Hsla, InteractiveElement as _,
    IntoElement, MouseButton, ParentElement as _, Render, SharedString,
    StatefulInteractiveElement as _, Styled as _, Subscription, Window, WindowControlArea, div,
    img, px,
};

use crate::pages::{
    Page, actions::ActionsPage, agent::AgentPage, ask::AskPage, meetings::MeetingsPage,
    people::PeoplePage, projects::ProjectsPage, timeline::TimelinePage, today::TodayPage,
};
use crate::state::{AppData, BackgroundItem, BackgroundKind, PrivacyLine, RecordingState, Section};
use crate::theme::UiFont as _;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

pub struct Workspace {
    data: Entity<AppData>,
    today: Entity<TodayPage>,
    actions: Entity<ActionsPage>,
    meetings: Entity<MeetingsPage>,
    timeline: Entity<TimelinePage>,
    people: Entity<PeoplePage>,
    projects: Entity<ProjectsPage>,
    ask: Entity<AskPage>,
    agent: Entity<AgentPage>,
    _subscriptions: Vec<Subscription>,
}

impl Workspace {
    pub fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let data = AppData::global(cx);
        let subscriptions = vec![cx.observe(&data, |_, data, cx| {
            // The Actions row's count follows the library.
            data.update(cx, |data, cx| data.refresh_open_action_count(cx));
            cx.notify();
        })];
        data.update(cx, |data, cx| data.refresh_open_action_count(cx));
        crate::agent_handoff::refresh_in_background();
        Self {
            today: cx.new(|cx| TodayPage::new(window, cx)),
            actions: cx.new(|cx| ActionsPage::new(window, cx)),
            meetings: cx.new(|cx| MeetingsPage::new(window, cx)),
            timeline: cx.new(|cx| TimelinePage::new(window, cx)),
            people: cx.new(|cx| PeoplePage::new(window, cx)),
            projects: cx.new(|cx| ProjectsPage::new(window, cx)),
            ask: cx.new(|cx| AskPage::new(window, cx)),
            agent: cx.new(|cx| AgentPage::new(window, cx)),
            data,
            _subscriptions: subscriptions,
        }
    }

    fn page_parts(
        &mut self,
        section: Section,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> PageParts {
        fn parts<P: Page>(page: &Entity<P>, window: &mut Window, cx: &mut App) -> PageParts {
            let (title, subtitle, toolbar, title_control) = page.update(cx, |page, cx| {
                (
                    page.title(cx),
                    page.subtitle(cx),
                    page.toolbar(window, cx),
                    page.title_control(window, cx),
                )
            });
            PageParts {
                title,
                subtitle,
                toolbar,
                title_control,
                page: page.clone().into_any_element(),
            }
        }
        match section {
            Section::Today => parts(&self.today, window, cx),
            Section::Actions => parts(&self.actions, window, cx),
            Section::Meetings => parts(&self.meetings, window, cx),
            Section::Timeline => parts(&self.timeline, window, cx),
            Section::People => parts(&self.people, window, cx),
            Section::Projects => parts(&self.projects, window, cx),
            Section::Ask => parts(&self.ask, window, cx),
            Section::Agent => parts(&self.agent, window, cx),
        }
    }

    /// Today and Actions lead; Remember holds what was captured; Assistant
    /// holds the two places you ask for work. Settings and the privacy line
    /// sit in the footer, outside the destinations (`MainWindowView.sidebar`).
    fn render_sidebar(&self, section: Section, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let open_actions = self
            .data
            .read(cx)
            .open_action_count
            .filter(|count| *count > 0);
        let item = |target: Section, count: Option<usize>, cx: &mut Context<Self>| {
            let selected = section == target;
            let data = self.data.clone();
            sidebar_row(
                SharedString::from(format!("sidebar-{target:?}").to_lowercase()),
                target.icon(),
                target.title(),
                selected,
                &lb,
            )
            .when_some(count, |this, count| {
                this.child(
                    div()
                        .id("sidebar-actions-count")
                        .flex_none()
                        .text_size(ty::CAPTION)
                        .text_color(lb.text_secondary)
                        .child(lokalbot_i18n::number(count)),
                )
            })
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
                    .id("sidebar-destinations")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .pt_1()
                    .gap(px(2.))
                    .child(item(Section::Today, None, cx))
                    .child(item(Section::Actions, open_actions, cx))
                    .child(header(lokalbot_i18n::tr("Remember"), 10.))
                    .child(item(Section::Meetings, None, cx))
                    .child(item(Section::Timeline, None, cx))
                    .child(item(Section::People, None, cx))
                    .child(item(Section::Projects, None, cx))
                    .child(header(lokalbot_i18n::tr("Assistant"), 14.))
                    .child(item(Section::Ask, None, cx))
                    .child(item(Section::Agent, None, cx)),
            )
            .child(self.render_sidebar_footer(cx))
    }

    /// The app mark at the top of the sidebar; also a window drag handle.
    /// The Mac has its window buttons here instead.
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

    /// The sidebar's foot: what is running now, then Settings, then where
    /// the library and the AI are (`SidebarFooter`).
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
        let privacy = data.privacy.clone();
        let companion_line = data
            .settings
            .companion_sharing_enabled
            .then(|| companion_line(data.companion.devices.len()));
        let data_entity = self.data.clone();
        let settings_data = self.data.clone();

        v_flex()
            .flex_none()
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
                let all = background.clone();
                let list_data = data_entity.clone();
                this.child(
                    ui::grouped_surface(cx)
                        .p(px(10.))
                        .child(background_row(
                            "sidebar-background",
                            &first,
                            &data_entity,
                            cx,
                        ))
                        .when(more > 0, |this| {
                            this.child(
                                Popover::new("sidebar-background-more")
                                    .anchor(gpui_kit::Anchor::BottomLeft)
                                    .trigger(
                                        Button::new("sidebar-background-more-button")
                                            .text()
                                            .xsmall()
                                            .tooltip(lokalbot_i18n::tr("Show all background work"))
                                            .label(lokalbot_i18n::format(
                                                "+{more} more",
                                                &[("more", format!("{}", more))],
                                            )),
                                    )
                                    .content(move |_, _, cx| {
                                        let lb = cx.lb().clone();
                                        v_flex()
                                            .w(px(300.))
                                            .gap(px(10.))
                                            .child(
                                                div()
                                                    .text_size(ty::SECTION)
                                                    .font_weight(FontWeight::BOLD)
                                                    .text_color(lb.text)
                                                    .child(crate::ui::text::paragraph(
                                                        lokalbot_i18n::tr("In progress"),
                                                    )),
                                            )
                                            .children(all.iter().enumerate().map(|(ix, item)| {
                                                background_row(
                                                    SharedString::from(format!(
                                                        "sidebar-background-{ix}"
                                                    )),
                                                    item,
                                                    &list_data,
                                                    cx,
                                                )
                                            }))
                                    }),
                            )
                        }),
                )
            })
            .child(
                v_flex()
                    .gap(px(2.))
                    // Settings is a place you visit rarely, so it sits at the
                    // foot and not among the destinations. It opens the
                    // Settings window and is never selected: the main window
                    // stays where it was (`SidebarSettingsRow`).
                    .child(
                        sidebar_row(
                            "sidebar-settings",
                            Ico::Settings,
                            lokalbot_i18n::tr("Settings"),
                            false,
                            &lb,
                        )
                        .mx_0()
                        .on_click(move |_, _, cx| {
                            settings_data.update(cx, |data, cx| {
                                let category = data.settings_category;
                                data.open_settings(category, cx)
                            })
                        }),
                    )
                    .child(privacy_line(&privacy, companion_line, &lb)),
            )
    }

    fn render_toolbar(
        &self,
        title: SharedString,
        subtitle: Option<SharedString>,
        toolbar: Option<AnyElement>,
        title_control: Option<AnyElement>,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let title_bar = TitleBar::new()
            .h(metric::TOOLBAR_HEIGHT)
            .bg(lb.title_bar)
            .border_color(lb.separator);
        let title_bar = match title_control {
            // The control takes clicks; the rest of the bar still drags the window.
            Some(control) => title_bar.child(
                div()
                    .pl(px(12.))
                    .min_w_0()
                    .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                    .child(control),
            ),
            None => title_bar.child(
                v_flex()
                    .pl(px(16.))
                    .min_w_0()
                    .justify_center()
                    .child(
                        div()
                            .text_size(ty::COLUMN_TITLE)
                            .font_weight(FontWeight::BOLD)
                            .text_color(lb.text)
                            .truncate()
                            .child(title),
                    )
                    .when_some(subtitle, |this, subtitle| {
                        this.child(
                            div()
                                .text_size(ty::TOOLBAR_SUBTITLE)
                                .text_color(lb.text_secondary)
                                .truncate()
                                .child(subtitle),
                        )
                    }),
            ),
        };
        title_bar.child(
            h_flex()
                .h_full()
                .items_center()
                .gap_1()
                .pr_2()
                .on_mouse_down(MouseButton::Left, |_, _, cx| cx.stop_propagation())
                .children(toolbar),
        )
    }
}

/// What the shell takes from the current page.
struct PageParts {
    title: SharedString,
    subtitle: Option<SharedString>,
    toolbar: Option<AnyElement>,
    title_control: Option<AnyElement>,
    page: AnyElement,
}

/// A row in the sidebar's style: icon, title, then whatever the caller adds
/// (a count). The selected row gets the selection fill.
fn sidebar_row(
    id: impl Into<gpui_kit::ElementId>,
    icon: Ico,
    title: &'static str,
    selected: bool,
    lb: &crate::theme::Palette,
) -> gpui_kit::Stateful<gpui_kit::Div> {
    let hover = lb.hover;
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
        .when(!selected, |this| this.hover(move |style| style.bg(hover)))
        .child(ui::icon(icon, px(16.), lb.accent_text))
        .child(
            div()
                .flex_1()
                .min_w_0()
                .truncate()
                .text_size(ty::BODY)
                .text_color(lb.text)
                .when(selected, |this| this.font_weight(FontWeight::MEDIUM))
                .child(title),
        )
}

/// Where the library and the AI are, under Settings (`SidebarPrivacyLine`),
/// with the paired devices line while sharing is on.
fn privacy_line(
    privacy: &PrivacyLine,
    companion_line: Option<String>,
    lb: &crate::theme::Palette,
) -> impl IntoElement + use<> {
    let line = |text: SharedString| {
        div()
            .text_size(ty::CAPTION)
            .text_color(lb.supporting)
            .child(crate::ui::text::paragraph(text))
    };
    let lines: Vec<AnyElement> = match privacy {
        PrivacyLine::Local => vec![line(lokalbot_i18n::tr("On this PC").into()).into_any_element()],
        PrivacyLine::Split { blocked, hosts } => {
            let mut lines = vec![
                line(lokalbot_i18n::tr("Storage: this PC").into()).into_any_element(),
                h_flex()
                    .gap(px(4.))
                    .items_center()
                    .child(line(PrivacyLine::ai_label(*blocked).into()))
                    .child(ui::status_dot(lb.attention, px(5.)))
                    .into_any_element(),
            ];
            lines.extend(
                hosts
                    .iter()
                    .map(|host| line(host.clone().into()).into_any_element()),
            );
            lines
        }
    };
    h_flex()
        .id("sidebar-privacy")
        .px(px(10.))
        .py(px(6.))
        .gap(px(10.))
        .items_start()
        .child(div().w(px(16.)).flex_none().pt(px(1.)).child(ui::icon(
            Ico::ShieldLock,
            px(16.),
            lb.accent_text,
        )))
        .child(
            v_flex()
                .flex_1()
                .min_w_0()
                .gap(px(3.))
                .children(lines)
                .when_some(companion_line, |this, text| this.child(line(text.into()))),
        )
}

/// The latest message or error, at the foot of a window (`ErrorToast`). The
/// main window and the Settings window both show it.
pub fn toast(data: &Entity<AppData>, cx: &App) -> Option<AnyElement> {
    let toast = data.read(cx).toast.clone()?;
    let lb = cx.lb().clone();
    let tint = if toast.is_error {
        lb.attention_text
    } else {
        lb.accent_text
    };
    let data = data.clone();
    Some(
        div()
            .p(px(12.))
            .child(
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
            )
            .into_any_element(),
    )
}

impl Render for Workspace {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let section = self.data.read(cx).section;
        let parts = self.page_parts(section, window, cx);
        let lb = cx.lb().clone();
        let toast = toast(&self.data, cx);

        h_flex()
            .size_full()
            .bg(lb.window)
            .text_color(lb.text)
            .ui_font()
            .child(self.render_sidebar(section, cx))
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .h_full()
                    .child(self.render_toolbar(
                        parts.title,
                        parts.subtitle,
                        parts.toolbar,
                        parts.title_control,
                        cx,
                    ))
                    .child(div().flex_1().min_h_0().relative().child(parts.page))
                    .children(toast),
            )
    }
}

/// One piece of background work; a click opens the screen that owns it
/// (`BackgroundActivityButton`).
fn background_row(
    id: impl Into<gpui_kit::ElementId>,
    item: &BackgroundItem,
    data: &Entity<AppData>,
    cx: &App,
) -> AnyElement {
    let lb = cx.lb();
    let destination = background_destination(item, data.read(cx).digest_running);
    let data = data.clone();
    h_flex()
        .id(id)
        .w_full()
        .child(
            v_flex()
                .w_full()
                .child(
                    h_flex()
                        .gap(px(8.))
                        .items_center()
                        .child(ui::icon(
                            background_icon(item.kind),
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
                                .child(item.title.clone()),
                        ),
                )
                .child(
                    div()
                        .mt(px(2.))
                        .text_size(ty::CAPTION)
                        .text_color(lb.text_secondary)
                        .child(item.detail.clone()),
                )
                .when_some(item.progress, |this, progress| {
                    this.child(progress_line(progress, lb.accent_fill, lb.chip_fill))
                }),
        )
        .when_some(destination, |this, destination| {
            let hover = lb.hover;
            this.cursor_pointer()
                .rounded(metric::ROW_RADIUS)
                .hover(move |s| s.bg(hover))
                .on_click(move |_, _, cx| {
                    data.update(cx, |data, cx| open_background(data, destination, cx));
                })
        })
        .into_any_element()
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum BackgroundDestination {
    Meeting(uuid::Uuid),
    Day(chrono::NaiveDate),
    Models,
}

/// The screen that owns a piece of work (`BackgroundActivity.destination`).
fn background_destination(
    item: &BackgroundItem,
    digest_day: Option<chrono::NaiveDate>,
) -> Option<BackgroundDestination> {
    match item.kind {
        BackgroundKind::Meeting => item
            .id
            .strip_prefix("meeting:")
            .and_then(|id| uuid::Uuid::parse_str(id).ok())
            .map(BackgroundDestination::Meeting),
        BackgroundKind::Digest => digest_day.map(BackgroundDestination::Day),
        BackgroundKind::Download => Some(BackgroundDestination::Models),
        BackgroundKind::Reindex => None,
    }
}

fn open_background(
    data: &mut AppData,
    destination: BackgroundDestination,
    cx: &mut Context<AppData>,
) {
    match destination {
        BackgroundDestination::Meeting(id) => {
            data.open_meeting(id, Default::default(), None, cx);
        }
        BackgroundDestination::Day(day) if day == chrono::Local::now().date_naive() => {
            data.navigate(Section::Today, cx)
        }
        BackgroundDestination::Day(day) => data.open_timeline(day, None, cx),
        BackgroundDestination::Models => {
            data.open_settings(crate::state::SettingsCategory::Models, cx)
        }
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

/// What the privacy line says about paired phones and tablets
/// (`SidebarCompanionLine`).
fn companion_line(devices: usize) -> String {
    match devices {
        0 => lokalbot_i18n::tr("Phones & tablets: none paired").to_string(),
        1 => lokalbot_i18n::tr("Copy on 1 paired device").to_string(),
        many => lokalbot_i18n::mac(
            "Copies on %lld paired devices",
            &[&lokalbot_i18n::number(many)],
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: &str, kind: BackgroundKind) -> BackgroundItem {
        BackgroundItem {
            id: id.into(),
            kind,
            title: "t".into(),
            detail: "d".into(),
            progress: None,
        }
    }

    #[test]
    fn background_work_opens_its_own_screen() {
        let id = uuid::Uuid::from_u128(7);
        let day = chrono::NaiveDate::from_ymd_opt(2026, 10, 2).unwrap();
        assert_eq!(
            background_destination(
                &item(&format!("meeting:{id}"), BackgroundKind::Meeting),
                None
            ),
            Some(BackgroundDestination::Meeting(id))
        );
        assert_eq!(
            background_destination(&item("meeting-queue", BackgroundKind::Meeting), None),
            None,
            "the queue has no single meeting"
        );
        assert_eq!(
            background_destination(&item("digest", BackgroundKind::Digest), Some(day)),
            Some(BackgroundDestination::Day(day))
        );
        assert_eq!(
            background_destination(&item("download:x", BackgroundKind::Download), None),
            Some(BackgroundDestination::Models)
        );
        assert_eq!(
            background_destination(&item("reindex", BackgroundKind::Reindex), None),
            None
        );
    }

    #[test]
    fn the_privacy_line_counts_paired_devices() {
        assert_eq!(companion_line(0), "Phones & tablets: none paired");
        assert_eq!(companion_line(1), "Copy on 1 paired device");
        assert_eq!(companion_line(3), "Copies on 3 paired devices");
    }
}
