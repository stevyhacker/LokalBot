//! The list column (`ProjectsListColumn`): the search field and the add
//! button as its header, then tracked projects and suggestions. Hidden
//! suggestions are shown again from its foot.

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::Input;
use gpui_kit::component::menu::ContextMenuExt as _;
use gpui_kit::component::tooltip::Tooltip;
use gpui_kit::component::{Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, Context, FontWeight, InteractiveElement as _, IntoElement, ParentElement as _,
    SharedString, StatefulInteractiveElement as _, Styled as _, div, px,
};

use super::ProjectsPage;
use super::model::{self, Row};
use crate::i18n::h_flex;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico, profile};
use lokalbot_i18n::fill;

impl ProjectsPage {
    pub(super) fn render_list(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let settling = self.settling();
        let content = self.list_content(settling.as_ref());
        let selected_id = self.selected_project().map(|(p, _)| p.id);
        let shown = model::list_projects(&self.projects, settling.as_ref());
        let mut rows: Vec<AnyElement> = Vec::new();
        for (group, title) in [
            (&content.tracked, lokalbot_i18n::tr("Tracked")),
            (&content.suggested, lokalbot_i18n::tr("Suggested")),
        ] {
            if group.is_empty() {
                continue;
            }
            // A heading row, as in the People and Meetings lists: it scrolls
            // with its projects.
            rows.push(
                div()
                    .px(px(18.))
                    .pt(px(12.))
                    .pb(px(4.))
                    .text_size(ty::CAPTION)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.supporting)
                    .child(title)
                    .into_any_element(),
            );
            for row in group {
                let project = shown.iter().find(|p| p.id == row.id).copied();
                rows.push(self.render_row(
                    row,
                    project,
                    selected_id.as_deref() == Some(row.id.as_str()),
                    cx,
                ));
            }
        }
        let no_projects = self.projects.is_empty() && self.curation.tracked.is_empty();
        if !self.loaded && self.projects.is_empty() {
            rows.push(overlay(lokalbot_i18n::tr("Loading…"), cx));
        } else if self.loaded && no_projects {
            let page = cx.entity();
            rows.push(
                v_flex()
                    .w_full()
                    .items_center()
                    .gap(px(10.))
                    .p(px(24.))
                    .child(
                        div()
                            .w_full()
                            .text_center()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(ui::text::paragraph(fill(
                                lokalbot_i18n::tr(
                                    "Add the projects you work on, and LokalBot gathers their meetings, actions, and decisions. It also suggests names that come up in %lld or more meetings.",
                                ),
                                &[&lokalbot_i18n::number(model::MINIMUM_MEETINGS)],
                            ))),
                    )
                    .child(
                        Button::new("projects-track-empty")
                            .outline()
                            .label(lokalbot_i18n::tr("Track a project"))
                            .on_click(move |_, window, cx| {
                                page.update(cx, |page, cx| page.open_name_sheet(None, window, cx))
                            }),
                    )
                    .into_any_element(),
            );
        } else if content.is_empty() && !self.projects.is_empty() {
            rows.push(overlay(lokalbot_i18n::tr("No matches"), cx));
        }
        if !self.curation.hidden_names.is_empty() {
            let page = cx.entity();
            rows.push(
                div()
                    .px(px(18.))
                    .py(px(10.))
                    .child(profile::link(
                        "projects-restore-hidden",
                        model::show_hidden(self.curation.hidden_names.len()),
                        move |_, cx| page.update(cx, |page, cx| page.restore_hidden(cx)),
                        cx,
                    ))
                    .into_any_element(),
            );
        }
        let page = cx.entity();
        v_flex()
            .size_full()
            .child(
                h_flex()
                    .gap(px(6.))
                    .items_center()
                    .px(px(10.))
                    .pt(px(10.))
                    .pb(px(8.))
                    .child(div().flex_1().min_w_0().child(
                        Input::new(&self.search).cleanable(true).prefix(ui::icon(
                            Ico::Search,
                            px(14.),
                            lb.text_secondary,
                        )),
                    ))
                    .child(
                        Button::new("projects-add")
                            .ghost()
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
                    .track_scroll(&self.list_scroll)
                    .pb(px(12.))
                    .children(rows),
            )
    }

    /// One project in the list (`ProjectRow`): its monogram and name, when it
    /// was last active or where the suggestion came from, and the user's
    /// open actions. A project quiet for weeks is drawn fainter.
    fn render_row(
        &self,
        row: &Row,
        project: Option<&lokalbot_core::ProjectProfile>,
        selected: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let id = row.id.clone();
        let page = cx.entity();
        let menu_project = project.cloned();
        let tracked = self.curation.tracked.clone();
        let count: Option<AnyElement> = (row.open_actions > 0).then(|| {
            let label: SharedString = model::open_actions(row.open_actions).into();
            div()
                .id(SharedString::from(format!("project-row-open-{}", row.id)))
                .flex_none()
                .text_size(ty::SECONDARY)
                .text_color(lb.supporting)
                .child(lokalbot_i18n::number(row.open_actions))
                .tooltip(move |window, cx| Tooltip::new(label.clone()).build(window, cx))
                .into_any_element()
        });
        h_flex()
            .id(SharedString::from(format!("project-{}", row.id)))
            .mx(px(8.))
            .px(px(10.))
            .py(px(6.))
            .gap(px(10.))
            .items_center()
            .rounded(metric::ROW_RADIUS)
            .cursor_pointer()
            .when(selected, |this| this.bg(lb.sidebar_selection))
            .when(!selected, |this| this.hover(|s| s.bg(lb.hover)))
            .child(
                profile::monogram(&row.name, px(28.), row.is_suggestion, cx)
                    .when(row.is_quiet, |this| this.opacity(0.5)),
            )
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(2.))
                    .child(
                        div()
                            .truncate()
                            .text_size(ty::BODY)
                            .font_weight(if row.is_suggestion || row.is_quiet {
                                FontWeight::MEDIUM
                            } else {
                                FontWeight::SEMIBOLD
                            })
                            .text_color(if row.is_quiet { lb.supporting } else { lb.text })
                            .child(row.name.clone()),
                    )
                    .child(
                        div()
                            .truncate()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.supporting)
                            .child(row.detail.clone()),
                    ),
            )
            .children(count)
            .on_click(cx.listener(move |this, _, _, cx| {
                this.select(Some(id.clone()));
                cx.notify();
            }))
            .context_menu(move |menu, window, cx| match &menu_project {
                Some(project) => super::project_menu(menu, &page, project, &tracked, window, cx),
                None => menu,
            })
            .into_any_element()
    }
}

/// A quiet line over the list where projects would be.
fn overlay(text: &str, cx: &Context<ProjectsPage>) -> AnyElement {
    div()
        .w_full()
        .p(px(24.))
        .text_center()
        .text_size(ty::SECONDARY)
        .text_color(cx.lb().text_secondary)
        .child(ui::text::paragraph(text.to_string()))
        .into_any_element()
}
