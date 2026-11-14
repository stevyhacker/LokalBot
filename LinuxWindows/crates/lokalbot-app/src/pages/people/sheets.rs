//! The two corrections that open a sheet: choosing the name People shows
//! for someone (`PersonNameSheet`) and folding one person into another
//! (`PersonMergeSheet`).

use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::{Disableable as _, WindowExt as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, AppContext as _, Context, Entity, FontWeight, InteractiveElement as _, IntoElement,
    ParentElement as _, Render, SharedString, StatefulInteractiveElement as _, Styled as _,
    Subscription, Window, div, px,
};
use lokalbot_core::PersonProfile;

use super::PeoplePage;
use super::model;
use crate::i18n::h_flex;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, profile};

impl PeoplePage {
    /// Chooses the name People shows for someone. The names meetings used
    /// stay as other names, and the chosen one is recognized in notes and
    /// owners. "Use Name from Meetings" shows only once a name was chosen.
    pub(super) fn open_rename(
        &mut self,
        person: &PersonProfile,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let name = person.name.clone();
        self.rename_input
            .update(cx, |input, cx| input.set_value(name.clone(), window, cx));
        let page = cx.entity();
        let input = self.rename_input.clone();
        let person_id = person.id.clone();
        let members = person.member_ids.clone();
        let has_chosen_name = self.chosen_name(person).is_some();
        window.open_dialog(cx, move |dialog, _, cx| {
            let lb = cx.lb().clone();
            let save_page = page.clone();
            let reset_page = page.clone();
            let save_input = input.clone();
            let (save_id, reset_id) = (person_id.clone(), person_id.clone());
            let (save_members, reset_members) = (members.clone(), members.clone());
            let empty = input.read(cx).value().trim().is_empty();
            dialog
                .title(lokalbot_i18n::format("Rename {name}", &[("name", name.to_string())]))
                .w(px(440.))
                .child(
                    v_flex()
                        .gap(px(12.))
                        .child(Input::new(&input))
                        .child(
                            div()
                                .text_size(ty::SECONDARY)
                                .text_color(lb.text_secondary)
                                .child(ui::text::paragraph(lokalbot_i18n::tr(
                                    "People shows this name, and LokalBot also recognizes it in meeting notes and action owners. Names from your meetings stay listed as other names.",
                                ))),
                        )
                        .child(
                            h_flex()
                                .gap(px(8.))
                                .pt(px(4.))
                                .when(has_chosen_name, |this| {
                                    this.child(
                                        Button::new("people-rename-reset")
                                            .outline()
                                            .label(lokalbot_i18n::tr("Use Name from Meetings"))
                                            .on_click(move |_, window, cx| {
                                                reset_page.update(cx, |page, cx| {
                                                    page.rename(&reset_id, &reset_members, "", cx)
                                                });
                                                window.close_dialog(cx);
                                            }),
                                    )
                                })
                                .child(div().flex_1().min_w_0())
                                .child(
                                    Button::new("people-rename-cancel")
                                        .outline()
                                        .label(lokalbot_i18n::tr("Cancel"))
                                        .on_click(|_, window, cx| window.close_dialog(cx)),
                                )
                                .child(
                                    Button::new("people-rename-save")
                                        .primary()
                                        .label(lokalbot_i18n::tr("Save"))
                                        .disabled(empty)
                                        .on_click(move |_, window, cx| {
                                            let value = save_input.read(cx).value().to_string();
                                            if value.trim().is_empty() {
                                                return;
                                            }
                                            save_page.update(cx, |page, cx| {
                                                page.rename(&save_id, &save_members, &value, cx)
                                            });
                                            window.close_dialog(cx);
                                        }),
                                ),
                        ),
                )
        });
    }

    /// Folds one person into another (`PersonMergeSheet`).
    pub(super) fn open_merge(
        &mut self,
        person: &PersonProfile,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let mut candidates: Vec<PersonProfile> = self
            .people
            .iter()
            .filter(|p| p.id != person.id)
            .cloned()
            .collect();
        candidates.sort_by_key(|p| p.name.to_lowercase());
        let page = cx.entity();
        let person = person.clone();
        let sheet = cx.new(|cx| MergeSheet::new(page, person, candidates, window, cx));
        window.open_dialog(cx, move |dialog, _, _| {
            dialog.w(px(440.)).child(sheet.clone())
        });
    }
}

/// Folds one person into another: for a name heard wrong, a nickname, or
/// someone who joined from two addresses.
struct MergeSheet {
    page: Entity<PeoplePage>,
    person: PersonProfile,
    candidates: Vec<PersonProfile>,
    search: Entity<InputState>,
    selection: Option<String>,
    _search_changed: Subscription,
}

impl MergeSheet {
    fn new(
        page: Entity<PeoplePage>,
        person: PersonProfile,
        candidates: Vec<PersonProfile>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let search = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                "Search people",
                window,
                cx,
            ))
        });
        search.update(cx, |input, cx| input.focus(window, cx));
        let search_changed = cx.subscribe(&search, |_, _, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                cx.notify();
            }
        });
        Self {
            page,
            person,
            candidates,
            search,
            selection: None,
            _search_changed: search_changed,
        }
    }

    fn merge(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let target = self
            .selection
            .as_deref()
            .and_then(|id| self.candidates.iter().find(|c| c.id == id))
            .cloned();
        if let Some(target) = target {
            let source = self.person.clone();
            self.page
                .update(cx, |page, cx| page.merge(&source, &target, cx));
        }
        window.close_dialog(cx);
    }
}

impl Render for MergeSheet {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let needle = self.search.read(cx).value().trim().to_lowercase();
        let name = self.person.name.clone();
        let rows: Vec<AnyElement> = self
            .candidates
            .iter()
            .filter(|c| {
                needle.is_empty()
                    || std::iter::once(&c.name)
                        .chain(c.other_names.iter())
                        .any(|n| n.to_lowercase().contains(&needle))
            })
            .map(|candidate| {
                let selected = self.selection.as_deref() == Some(candidate.id.as_str());
                let id = candidate.id.clone();
                h_flex()
                    .id(SharedString::from(format!("merge-{}", candidate.id)))
                    .px(px(8.))
                    .py(px(5.))
                    .gap(px(8.))
                    .items_center()
                    .rounded(metric::ROW_RADIUS)
                    .cursor_pointer()
                    .when(selected, |this| this.bg(lb.sidebar_selection))
                    .when(!selected, |this| this.hover(|s| s.bg(lb.hover)))
                    .child(ui::avatar(
                        model::initials(&candidate.name),
                        profile::name_tint(&candidate.name, cx),
                        px(22.),
                    ))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(ty::BODY)
                            .text_color(lb.text)
                            .child(candidate.name.clone()),
                    )
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(profile::count(candidate.meeting_count(), "meeting")),
                    )
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.selection = Some(id.clone());
                        cx.notify();
                    }))
                    .into_any_element()
            })
            .collect();
        v_flex()
            .gap(px(12.))
            .child(
                div()
                    .text_size(ty::QUESTION)
                    .font_weight(FontWeight::BOLD)
                    .text_color(lb.text)
                    .child(lokalbot_i18n::format(
                        "Merge {name} Into…",
                        &[("name", name.clone())],
                    )),
            )
            .child(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(ui::text::paragraph(lokalbot_i18n::format(
                        "Choose who {name} really is. Their meetings, open work, and decisions move to that person, and {name} becomes another name. Separate them again from that person's More menu.",
                        &[("name", name)],
                    ))),
            )
            .child(Input::new(&self.search).cleanable(true))
            .child(
                v_flex()
                    .id("people-merge-list")
                    .h(px(240.))
                    .overflow_y_scroll()
                    .rounded(metric::GROUP_RADIUS)
                    .border_1()
                    .border_color(lb.group_stroke)
                    .p(px(4.))
                    .children(rows),
            )
            .child(
                h_flex()
                    .gap(px(8.))
                    .pt(px(4.))
                    .child(div().flex_1().min_w_0())
                    .child(
                        Button::new("people-merge-cancel")
                            .outline()
                            .label(lokalbot_i18n::tr("Cancel"))
                            .on_click(|_, window, cx| window.close_dialog(cx)),
                    )
                    .child(
                        Button::new("people-merge-save")
                            .primary()
                            .label(lokalbot_i18n::tr("Merge"))
                            .disabled(self.selection.is_none())
                            .on_click(cx.listener(|this, _, window, cx| this.merge(window, cx))),
                    ),
            )
    }
}
