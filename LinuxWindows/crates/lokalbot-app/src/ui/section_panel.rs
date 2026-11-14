//! Section panels (`SectionPanel.swift`): one section of a page on its own
//! raised surface. Today, a meeting's Summary, Transcript and Notes, and
//! Timeline's day are made of these.
//!
//! A panel has a header bar (the section's icon, its title, a count pill, an
//! optional red alert pill or status pill, and one trailing link),
//! a hairline, a body, and an optional footer strip on a faint fill for the
//! one extra line a section has.
//!
//! ```ignore
//! use crate::ui::section_panel::{SectionPanel, Pill, footer_text};
//!
//! SectionPanel::new("today-attention", lokalbot_i18n::tr("Needs attention"))
//!     .section(Section::Actions) // the sidebar destination's icon
//!     .count(open)
//!     .when(overdue > 0, |p| p.alert(overdue_label))
//!     .trailing_link("today-all-actions", lokalbot_i18n::tr("All actions"), |_, cx| {
//!         AppData::global(cx).update(cx, |data, cx| data.open_actions(cx))
//!     })
//!     .rows(threads.iter().enumerate().map(|(ix, thread)| {
//!         action_row::thread_row(format!("today-thread-{ix}").into(), thread,
//!             Default::default(), &data, cx)
//!     }))
//!     .footer(footer_text(showing))
//!     .footer(panel_link("today-more-actions", more, |_, cx| { /* open Actions */ }, cx))
//! ```
//!
//! Put panels on [`page_surface`] (the grey page behind them) so they read
//! as raised, and stack them in a [`panel_column`].

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, BoxShadow, Div, ElementId, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, RenderOnce, SharedString, Styled as _, Window, div, hsla, point, px,
};

use super::{Ico, icon};
use crate::state::Section;
use crate::theme::{LbThemeExt as _, metric, ty};

/// What a pill beside a panel's title says (`SectionPanelPill.Tone`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PillTone {
    /// The count beside the title: quiet fill, supporting text.
    Count,
    /// A red badge, such as "1 overdue".
    Overdue,
    /// The accent badge that says a section is finished ("All done").
    Done,
}

/// A count, overdue or done pill. Use [`count_pill`] for a number.
pub fn pill(text: impl Into<SharedString>, tone: PillTone, cx: &App) -> Div {
    let lb = cx.lb();
    let (fill, color) = match tone {
        PillTone::Count => (lb.quiet_fill, lb.supporting),
        PillTone::Overdue => (lb.status_fill(lb.recording), lb.overdue_text),
        PillTone::Done => (lb.status_fill(lb.accent_fill), lb.accent_text),
    };
    div()
        .flex_none()
        .min_w(px(20.))
        .h(px(19.))
        .px(px(6.))
        .flex()
        .items_center()
        .justify_center()
        .rounded_full()
        .bg(fill)
        .text_size(ty::PILL)
        .font_weight(FontWeight::SEMIBOLD)
        .text_color(color)
        .child(text.into())
}

/// The count beside a panel's title, in the interface's digits.
pub fn count_pill(count: usize, cx: &App) -> Div {
    pill(lokalbot_i18n::number(count), PillTone::Count, cx)
}

/// A small bold label over a group inside a panel ("Highlights",
/// "Priorities for today") (`SectionPanelLabel`).
pub fn panel_label(text: impl Into<SharedString>, cx: &App) -> Div {
    div()
        .w_full()
        .text_size(ty::PILL)
        .font_weight(FontWeight::BOLD)
        .text_color(cx.lb().supporting)
        .child(text.into())
}

/// A labelled band across a panel's body over a group of its rows ("For you
/// · 2") (`SectionPanelBand`). It carries the footer's fill with a hairline
/// under it; `follows_rows` also draws the hairline above, for a band after
/// rows.
pub fn panel_band(text: impl Into<SharedString>, follows_rows: bool, cx: &App) -> Div {
    let lb = cx.lb();
    v_flex()
        .w_full()
        .when(follows_rows, |this| this.child(super::divider(cx)))
        .child(
            h_flex()
                .w_full()
                .min_h(metric::PANEL_BAND_HEIGHT)
                .px(metric::PANEL_INSET)
                .items_center()
                .bg(lb.group_fill)
                .child(
                    div()
                        .min_w_0()
                        .truncate()
                        .text_size(ty::PILL)
                        .font_weight(FontWeight::BOLD)
                        .text_color(lb.supporting)
                        .child(text.into()),
                ),
        )
        .child(super::divider(cx))
}

/// The words of a footer strip: they take the strip's width and wrap, and a
/// link after them keeps to the trailing edge (`sectionPanelFooterText`).
pub fn footer_text(text: impl Into<SharedString>) -> Div {
    div()
        .flex_1()
        .min_w_0()
        .child(super::text::paragraph(text.into()))
}

/// The grey page behind panels, so each panel reads as a raised surface.
/// Pages that are made of panels fill their scroll area with it.
pub fn page_surface(cx: &App) -> Div {
    div().bg(cx.lb().page)
}

/// A column of panels with the space the Mac leaves between them.
pub fn panel_column() -> Div {
    v_flex().w_full().gap(metric::PANEL_SPACING)
}

/// The raised surface every panel and lead uses: the panel fill, a faint
/// edge and a soft shadow (`todayCardSurface`).
pub fn panel_surface(cx: &App) -> Div {
    let lb = cx.lb();
    div()
        .w_full()
        .rounded(metric::GROUP_RADIUS)
        .bg(lb.panel)
        .border_1()
        .border_color(lb.group_stroke)
        .shadow(vec![BoxShadow {
            color: hsla(0., 0., 0., if lb.dark { 0.0 } else { 0.06 }),
            offset: point(px(0.), px(1.)),
            blur_radius: px(3.),
            spread_radius: px(0.),
            inset: false,
        }])
}

/// Makes the header the control that opens and closes the body: a chevron
/// takes the icon's place and the whole bar is one button.
struct Disclosure {
    expanded: bool,
    on_toggle: Handler,
}

type Handler = Box<dyn Fn(&mut Window, &mut App) + 'static>;

/// One section of a page on its own raised surface. Build it with the
/// methods below; it draws when added as a child.
///
/// - Header: [`icon`](Self::icon) or [`section`](Self::section), the title,
///   [`count`](Self::count), [`alert`](Self::alert) (red) or
///   [`status`](Self::status), then one [`trailing_link`](Self::trailing_link).
/// - Body, in the order added: [`rows`](Self::rows) (inset rows divided by
///   inset hairlines, like Needs attention), [`band`](Self::band) and free
///   [`child`](Self::child) content.
/// - [`footer`](Self::footer): each call adds to the strip; use
///   [`footer_text`] for its words.
/// - [`disclosure`](Self::disclosure): a collapsed panel whose header opens
///   it in place (Full summary).
#[derive(IntoElement)]
pub struct SectionPanel {
    id: ElementId,
    title: SharedString,
    icon: Option<Ico>,
    count: Option<usize>,
    alert: Option<SharedString>,
    status: Option<(SharedString, PillTone)>,
    trailing: Option<(ElementId, SharedString, Handler)>,
    title_lines: usize,
    disclosure: Option<Disclosure>,
    body: Vec<BodyPart>,
    footer: Vec<AnyElement>,
}

enum BodyPart {
    Rows(Vec<AnyElement>),
    Band(SharedString, bool),
    Child(AnyElement),
}

impl SectionPanel {
    /// `id` names the panel; its header and disclosure use ids derived from it.
    pub fn new(id: impl Into<ElementId>, title: impl Into<SharedString>) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            icon: None,
            count: None,
            alert: None,
            status: None,
            trailing: None,
            title_lines: 1,
            disclosure: None,
            body: Vec::new(),
            footer: Vec::new(),
        }
    }

    /// The icon beside the title.
    pub fn icon(mut self, icon: Ico) -> Self {
        self.icon = Some(icon);
        self
    }

    /// The icon of the sidebar destination this section leads to, as the
    /// Mac takes it from `NavSection.symbol`.
    pub fn section(self, section: Section) -> Self {
        self.icon(section.icon())
    }

    /// The count pill beside the title.
    pub fn count(mut self, count: usize) -> Self {
        self.count = Some(count);
        self
    }

    /// A red badge beside the count, such as "1 overdue".
    pub fn alert(mut self, text: impl Into<SharedString>) -> Self {
        self.alert = Some(text.into());
        self
    }

    /// A badge that says where the section stands, such as "2 open"
    /// (`PillTone::Count`) or "All done" (`PillTone::Done`).
    pub fn status(mut self, text: impl Into<SharedString>, tone: PillTone) -> Self {
        self.status = Some((text.into(), tone));
        self
    }

    /// A link at the header's trailing edge ("All actions", "Open Timeline").
    pub fn trailing_link(
        mut self,
        id: impl Into<ElementId>,
        label: impl Into<SharedString>,
        on_click: impl Fn(&mut Window, &mut App) + 'static,
    ) -> Self {
        self.trailing = Some((id.into(), label.into(), Box::new(on_click)));
        self
    }

    /// A long title may take this many lines in a narrow panel instead of
    /// being cut short.
    pub fn title_lines(mut self, lines: usize) -> Self {
        self.title_lines = lines.max(1);
        self
    }

    /// A collapsed panel: the header is one button with a chevron, and the
    /// body and footer show only while `expanded`.
    pub fn disclosure(
        mut self,
        expanded: bool,
        on_toggle: impl Fn(&mut Window, &mut App) + 'static,
    ) -> Self {
        self.disclosure = Some(Disclosure {
            expanded,
            on_toggle: Box::new(on_toggle),
        });
        self
    }

    /// Rows inset from the panel's edges, divided by inset hairlines.
    pub fn rows(mut self, rows: impl IntoIterator<Item = impl IntoElement>) -> Self {
        let rows: Vec<AnyElement> = rows.into_iter().map(|r| r.into_any_element()).collect();
        if !rows.is_empty() {
            self.body.push(BodyPart::Rows(rows));
        }
        self
    }

    /// A labelled band over the rows that follow ("For you · 2"). Pass
    /// `follows_rows` for a band that comes after other rows.
    pub fn band(mut self, text: impl Into<SharedString>, follows_rows: bool) -> Self {
        self.body.push(BodyPart::Band(text.into(), follows_rows));
        self
    }

    /// Free body content, edge to edge: pad it with `metric::PANEL_INSET`.
    pub fn child(mut self, element: impl IntoElement) -> Self {
        self.body.push(BodyPart::Child(element.into_any_element()));
        self
    }

    /// Adds to the footer strip, in order: words first
    /// ([`footer_text`]), then a [`panel_link`] that keeps to the trailing
    /// edge.
    pub fn footer(mut self, element: impl IntoElement) -> Self {
        self.footer.push(element.into_any_element());
        self
    }

    fn render_title(&self, cx: &App) -> Div {
        div()
            .min_w_0()
            .text_size(ty::PANEL_TITLE)
            .font_weight(FontWeight::BOLD)
            .text_color(cx.lb().text)
            .when(self.title_lines == 1, |this| this.truncate())
            .when(self.title_lines > 1, |this| {
                this.line_clamp(self.title_lines)
            })
            .child(self.title.clone())
    }
}

/// A teal link in a panel's header or footer ("All actions", "2 more in
/// Actions", "Update") (`.workspaceLink`). A button, so the keyboard reaches
/// it.
pub fn panel_link(
    id: impl Into<ElementId>,
    label: impl Into<SharedString>,
    on_click: impl Fn(&mut Window, &mut App) + 'static,
    cx: &App,
) -> AnyElement {
    Button::new(id)
        .text()
        .small()
        .text_color(cx.lb().accent_text)
        .label(label)
        .on_click(move |_, window, cx| on_click(window, cx))
        .into_any_element()
}

impl RenderOnce for SectionPanel {
    fn render(mut self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        let lb = cx.lb().clone();
        let expanded = self.disclosure.as_ref().is_none_or(|d| d.expanded);
        let title = self.render_title(cx);
        let header: AnyElement = match self.disclosure.take() {
            Some(disclosure) => {
                let chevron = if disclosure.expanded {
                    Ico::ChevronDown
                } else if lokalbot_i18n::current().rtl {
                    Ico::ChevronLeft
                } else {
                    Ico::ChevronRight
                };
                let toggle = disclosure.on_toggle;
                Button::new(ElementId::NamedChild(
                    std::sync::Arc::new(self.id.clone()),
                    "disclosure".into(),
                ))
                .ghost()
                .w_full()
                .h_auto()
                .child(
                    h_flex()
                        .w_full()
                        .min_h(metric::PANEL_HEADER_HEIGHT)
                        .pl(metric::PANEL_INSET - px(12.))
                        .gap(px(8.))
                        .items_center()
                        .child(div().w(px(18.)).flex().justify_center().child(icon(
                            chevron,
                            px(14.),
                            lb.supporting,
                        )))
                        .child(title)
                        .child(div().flex_1()),
                )
                .on_click(move |_, window, cx| toggle(window, cx))
                .into_any_element()
            }
            None => h_flex()
                .w_full()
                .min_h(metric::PANEL_HEADER_HEIGHT)
                .pl(metric::PANEL_INSET)
                .pr(metric::PANEL_INSET - px(4.))
                .py(px(6.))
                .gap(px(8.))
                .items_center()
                .when_some(self.icon, |this, name| {
                    this.child(
                        div()
                            .w(px(18.))
                            .flex_none()
                            .flex()
                            .justify_center()
                            .child(icon(name, px(15.), lb.accent_text)),
                    )
                })
                .child(title)
                .when_some(self.count, |this, count| this.child(count_pill(count, cx)))
                .when_some(self.alert.clone(), |this, alert| {
                    this.child(pill(alert, PillTone::Overdue, cx))
                })
                .when_some(self.status.clone(), |this, (text, tone)| {
                    this.child(pill(text, tone, cx))
                })
                .child(div().flex_1().min_w(px(8.)))
                .when_some(self.trailing.take(), |this, (id, label, on_click)| {
                    this.child(div().flex_none().child(panel_link(
                        id,
                        label,
                        move |window, cx| on_click(window, cx),
                        cx,
                    )))
                })
                .into_any_element(),
        };

        let has_body = !self.body.is_empty();
        let has_footer = !self.footer.is_empty();
        let body: Vec<AnyElement> = self
            .body
            .into_iter()
            .map(|part| render_part(part, cx))
            .collect();
        panel_surface(cx)
            .id(self.id)
            .flex()
            .flex_col()
            .child(header)
            .when(expanded && has_body, |this| {
                this.child(super::divider(cx))
                    .child(v_flex().w_full().children(body))
            })
            .when(expanded && has_footer, |this| {
                this.child(super::divider(cx)).child(
                    h_flex()
                        .w_full()
                        .min_h(metric::PANEL_FOOTER_HEIGHT)
                        .px(metric::PANEL_INSET)
                        .py(px(6.))
                        .gap(px(8.))
                        .items_center()
                        .rounded_b(metric::GROUP_RADIUS - px(1.))
                        .bg(lb.group_fill)
                        .text_size(ty::SECONDARY)
                        .text_color(lb.supporting)
                        .children(self.footer),
                )
            })
    }
}

fn render_part(part: BodyPart, cx: &App) -> AnyElement {
    match part {
        BodyPart::Rows(rows) => {
            let count = rows.len();
            v_flex()
                .w_full()
                .px(metric::PANEL_INSET)
                .children(rows.into_iter().enumerate().flat_map(|(ix, row)| {
                    let mut parts = vec![row];
                    if ix + 1 < count {
                        parts.push(super::divider(cx).into_any_element());
                    }
                    parts
                }))
                .into_any_element()
        }
        BodyPart::Band(text, follows_rows) => panel_band(text, follows_rows, cx).into_any_element(),
        BodyPart::Child(element) => element,
    }
}

/// A panel with no header bar: what a page leads with, such as a meeting's
/// recap or a session's title (`SectionPanelLead`). The content is padded;
/// [`below`](Self::below) runs edge to edge under a hairline.
///
/// ```ignore
/// SectionPanelLead::new("meeting-recap")
///     .child(recap_text)
///     .below(player_bar)
/// ```
#[derive(IntoElement)]
pub struct SectionPanelLead {
    id: ElementId,
    content: Vec<AnyElement>,
    below: Option<AnyElement>,
}

impl SectionPanelLead {
    pub fn new(id: impl Into<ElementId>) -> Self {
        Self {
            id: id.into(),
            content: Vec::new(),
            below: None,
        }
    }

    pub fn child(mut self, element: impl IntoElement) -> Self {
        self.content.push(element.into_any_element());
        self
    }

    /// A body under a hairline that runs edge to edge, for a lead that also
    /// holds what it names.
    pub fn below(mut self, element: impl IntoElement) -> Self {
        self.below = Some(element.into_any_element());
        self
    }
}

impl RenderOnce for SectionPanelLead {
    fn render(self, _window: &mut Window, cx: &mut App) -> impl IntoElement {
        panel_surface(cx)
            .id(self.id)
            .flex()
            .flex_col()
            .child(
                v_flex()
                    .w_full()
                    .px(metric::PANEL_INSET + px(2.))
                    .pt(px(15.))
                    .pb(px(16.))
                    .children(self.content),
            )
            .when_some(self.below, |this, below| {
                this.child(super::divider(cx)).child(
                    div()
                        .w_full()
                        .rounded_b(metric::GROUP_RADIUS - px(1.))
                        .overflow_hidden()
                        .child(below),
                )
            })
    }
}
