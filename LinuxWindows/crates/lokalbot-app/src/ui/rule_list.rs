//! Editable exclusion lists (`ExclusionRulesEditor.swift`): apps or sites that
//! LokalBot never captures or suggests in. Stored comma-separated in settings.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AppContext as _, Context, Entity, EventEmitter, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, Render, SharedString, StatefulInteractiveElement as _,
    Styled as _, Subscription, Window, div, px,
};

use super::{Ico, icon};
use crate::theme::{LbThemeExt as _, ty};

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum RuleKind {
    Applications,
    Domains,
}

pub enum RuleListEvent {
    /// The new comma-separated value.
    Changed(String),
}

pub struct RuleList {
    title: SharedString,
    kind: RuleKind,
    rules: Vec<String>,
    selected: Option<usize>,
    adding: bool,
    input: Entity<InputState>,
    error: Option<SharedString>,
    _subscription: Subscription,
}

impl EventEmitter<RuleListEvent> for RuleList {}

impl RuleList {
    pub fn new(
        title: &str,
        kind: RuleKind,
        value: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let placeholder = match kind {
            RuleKind::Applications => "Application name",
            RuleKind::Domains => "example.com",
        };
        let input = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::i18n::placeholder(
                placeholder,
                window,
                cx,
            ))
        });
        let subscription = cx.subscribe_in(
            &input,
            window,
            |this, _, event: &InputEvent, window, cx| match event {
                InputEvent::PressEnter { .. } => this.add(window, cx),
                InputEvent::Change if this.error.take().is_some() => cx.notify(),
                _ => {}
            },
        );
        Self {
            title: title.to_string().into(),
            kind,
            rules: lokalbot_core::settings::split_list(value),
            selected: None,
            adding: false,
            input,
            error: None,
            _subscription: subscription,
        }
    }

    /// Follows a change made elsewhere.
    pub fn set_value(&mut self, value: &str, cx: &mut Context<Self>) {
        let rules = lokalbot_core::settings::split_list(value);
        if rules != self.rules {
            self.rules = rules;
            self.selected = None;
            cx.notify();
        }
    }

    fn commit(&mut self, cx: &mut Context<Self>) {
        cx.emit(RuleListEvent::Changed(self.rules.join(", ")));
        cx.notify();
    }

    fn add(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let candidate = self.input.read(cx).value().trim().to_string();
        if let Some(problem) = validate(&candidate, self.kind, &self.rules) {
            self.error = Some(problem.into());
            cx.notify();
            return;
        }
        self.rules.push(candidate);
        self.adding = false;
        self.error = None;
        self.input
            .update(cx, |input, cx| input.set_value("", window, cx));
        self.commit(cx);
    }

    fn remove_selected(&mut self, cx: &mut Context<Self>) {
        if let Some(index) = self.selected.take()
            && index < self.rules.len()
        {
            self.rules.remove(index);
            self.commit(cx);
        }
    }
}

/// Why a rule cannot be added, if it cannot.
pub fn validate(candidate: &str, kind: RuleKind, existing: &[String]) -> Option<&'static str> {
    if candidate.is_empty() || candidate.contains(',') {
        return Some(lokalbot_i18n::tr("Add one rule at a time."));
    }
    if kind == RuleKind::Domains && !is_domain_rule(candidate) {
        return Some(lokalbot_i18n::tr(
            "Enter a domain or an HTTP(S) URL prefix. Existing rules remain unchanged.",
        ));
    }
    if existing
        .iter()
        .any(|rule| rule.eq_ignore_ascii_case(candidate))
    {
        return Some(lokalbot_i18n::tr("This rule is already excluded."));
    }
    None
}

fn is_domain_rule(candidate: &str) -> bool {
    if candidate.contains(char::is_whitespace) {
        return false;
    }
    let with_scheme = if candidate.contains("://") {
        candidate.to_string()
    } else {
        format!("https://{candidate}")
    };
    let Some((scheme, rest)) = with_scheme.split_once("://") else {
        return false;
    };
    let host = rest.split(['/', '?', '#']).next().unwrap_or_default();
    matches!(scheme.to_ascii_lowercase().as_str(), "http" | "https")
        && host.contains('.')
        && !host.starts_with('.')
}

impl Render for RuleList {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let (glyph, kind_label) = match self.kind {
            RuleKind::Applications => (Ico::LayoutGrid, lokalbot_i18n::tr("App")),
            RuleKind::Domains => (Ico::Globe, lokalbot_i18n::tr("Domain / URL")),
        };
        let rows: Vec<_> = self
            .rules
            .iter()
            .enumerate()
            .map(|(index, rule)| {
                let selected = self.selected == Some(index);
                h_flex()
                    .id(("rule", index))
                    .gap(px(8.))
                    .items_center()
                    .px(px(10.))
                    .py(px(5.))
                    .cursor_pointer()
                    .when(selected, |this| this.bg(lb.accent_wash))
                    .when(!selected, |this| this.hover(|s| s.bg(lb.hover)))
                    .child(icon(glyph, px(14.), lb.text_secondary))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(ty::BODY)
                            .text_color(lb.text)
                            .child(rule.clone()),
                    )
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(kind_label),
                    )
                    .on_click(cx.listener(move |this, _, _, cx| {
                        this.selected = if this.selected == Some(index) {
                            None
                        } else {
                            Some(index)
                        };
                        cx.notify();
                    }))
            })
            .collect();
        let empty = rows.is_empty();
        v_flex()
            .w_full()
            .gap(px(8.))
            .child(div().text_size(ty::SECONDARY).font_weight(FontWeight::SEMIBOLD).text_color(lb.text).child(crate::ui::text::paragraph(lokalbot_i18n::tr(&self.title).to_string())))
            .child(
                v_flex()
                    .w_full()
                    .rounded(px(8.))
                    .border_1()
                    .border_color(lb.separator)
                    .bg(lb.elevated)
                    .overflow_hidden()
                    .py(px(2.))
                    .children(rows)
                    .when(empty, |this| {
                        this.child(div().px(px(10.)).py(px(6.)).text_size(ty::SECONDARY).text_color(lb.text_secondary).child(crate::ui::text::paragraph(lokalbot_i18n::tr("No exclusions"))))
                    }),
            )
            .child(
                h_flex()
                    .gap(px(6.))
                    .child(
                        Button::new("rule-add")
                            .outline()
                            .xsmall()
                            .icon(Icon::new(Ico::Plus))
                            .tooltip(lokalbot_i18n::tr("Add Exclusion…"))
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.adding = true;
                                this.error = None;
                                this.input.update(cx, |input, cx| input.focus(window, cx));
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("rule-remove")
                            .outline()
                            .xsmall()
                            .icon(Icon::new(Ico::Minus))
                            .tooltip(lokalbot_i18n::tr("Remove Selected Exclusion"))
                            .disabled(self.selected.is_none())
                            .on_click(cx.listener(|this, _, _, cx| this.remove_selected(cx))),
                    ),
            )
            .when(self.adding, |this| {
                this.child(
                    h_flex()
                        .gap(px(6.))
                        .items_center()
                        .child(div().flex_1().min_w_0().child(Input::new(&self.input).small()))
                        .child(Button::new("rule-cancel").outline().small().label(lokalbot_i18n::tr("Cancel")).on_click(cx.listener(
                            |this, _, window, cx| {
                                this.adding = false;
                                this.error = None;
                                this.input.update(cx, |input, cx| input.set_value("", window, cx));
                                cx.notify();
                            },
                        )))
                        .child(
                            Button::new("rule-confirm")
                                .primary()
                                .small()
                                .label(lokalbot_i18n::tr("Add"))
                                .on_click(cx.listener(|this, _, window, cx| this.add(window, cx))),
                        ),
                )
            })
            .when_some(self.error.clone(), |this, error| {
                this.child(div().text_size(ty::SECONDARY).text_color(lb.attention_text).child(error))
            })
            .when(self.kind == RuleKind::Domains, |this| {
                this.child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Matches this domain and its subdomains. A pasted URL applies to its whole domain."))),
                )
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_rules() {
        let existing = vec!["1Password".to_string()];
        assert_eq!(
            validate("1password", RuleKind::Applications, &existing),
            Some("This rule is already excluded.")
        );
        assert_eq!(
            validate("a, b", RuleKind::Applications, &existing),
            Some("Add one rule at a time.")
        );
        assert!(validate("bank.example.com", RuleKind::Domains, &[]).is_none());
        assert!(validate("https://mail.example.com/private", RuleKind::Domains, &[]).is_none());
        assert!(validate("localhost", RuleKind::Domains, &[]).is_some());
        assert!(validate("ftp://x.y", RuleKind::Domains, &[]).is_some());
    }
}
