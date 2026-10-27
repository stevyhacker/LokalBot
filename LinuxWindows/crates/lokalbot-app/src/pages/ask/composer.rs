//! The composer dock (`AskView.composerDock`): filter chips, the evidence
//! boundary, answer sources, the input box and the inference status.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::calendar::Calendar;
use gpui_kit::component::input::Textarea;
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenu, PopupMenuItem};
use gpui_kit::component::popover::Popover;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, Div, Focusable as _, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _,
    Window, div, linear_color_stop, linear_gradient, px,
};
use lokalbot_core::settings::SummarizerBackend;

use super::AskPage;
use super::scope::{DateScope, Source};
use super::search::Facet;
use crate::state::SettingsCategory;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

/// Where answers are computed (`InferencePresentation`).
pub struct Inference {
    pub icon: Ico,
    pub label: SharedString,
    pub remote: bool,
    pub blocked: bool,
}

pub fn inference(cx: &App) -> Inference {
    let settings = &crate::state::AppData::global(cx).read(cx).settings;
    if let Some(plan) = settings.think_plan() {
        // A plan has its own approval entry, never a URL origin.
        return if plan.is_approved(settings) {
            Inference {
                icon: Ico::Network,
                label: lokalbot_i18n::format(
                    "Remote · {host}",
                    &[("host", plan.destination_host().to_string())],
                )
                .into(),
                remote: true,
                blocked: false,
            }
        } else {
            Inference {
                icon: Ico::TriangleAlert,
                label: lokalbot_i18n::tr("Model connection blocked").into(),
                remote: false,
                blocked: true,
            }
        };
    }
    let url = match settings.summarizer_backend {
        SummarizerBackend::Ollama => Some(settings.ollama_base_url.clone()),
        SummarizerBackend::OpenAICompatible => Some(settings.openai_base_url.clone()),
        SummarizerBackend::BuiltIn
        | SummarizerBackend::ChatGptPlan
        | SummarizerBackend::ClaudePlan => None,
    };
    let Some(url) = url.filter(|url| !lokalbot_core::access::is_loopback_url(url)) else {
        return Inference {
            icon: Ico::Monitor,
            label: lokalbot_i18n::tr("On this PC").into(),
            remote: false,
            blocked: false,
        };
    };
    if lokalbot_core::access::remote_block_reason(&url, &settings.approved_remote_inference_origins)
        .is_some()
    {
        return Inference {
            icon: Ico::TriangleAlert,
            label: lokalbot_i18n::tr("Model connection blocked").into(),
            remote: false,
            blocked: true,
        };
    }
    let host = lokalbot_core::access::origin_of(&url)
        .and_then(|origin| origin.split_once("://").map(|(_, host)| host.to_string()))
        .unwrap_or(url);
    Inference {
        icon: Ico::Network,
        label: lokalbot_i18n::format("Remote · {host}", &[("host", host.to_string())]).into(),
        remote: true,
        blocked: false,
    }
}

impl AskPage {
    pub(super) fn render_dock(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let searching = !self.query.trim().is_empty();
        let mut rows: Vec<AnyElement> = Vec::new();
        if let Some(filters) = self.render_filter_chips(cx) {
            rows.push(filters.into_any_element());
        }
        if let Some(scope) = &self.meeting_scope {
            let label = lokalbot_i18n::format(
                "{0} · All screens",
                &[(
                    "0",
                    super::history::count_label(scope.len(), "meeting").to_string(),
                )],
            );
            rows.push(
                h_flex()
                    .child(
                        Button::new("ask-evidence-scope")
                            .outline()
                            .small()
                            .icon(Icon::new(Ico::CircleX))
                            .label(label)
                            .tooltip(lokalbot_i18n::tr("Clear the selected evidence boundary"))
                            .on_click(cx.listener(|this, _, window, cx| {
                                this.meeting_scope = None;
                                this.scope_changed(window, cx);
                            })),
                    )
                    .into_any_element(),
            );
        }
        if searching {
            rows.push(self.render_answer_sources(cx).into_any_element());
        }
        rows.push(self.render_composer(window, cx).into_any_element());
        rows.push(self.render_inference_status(cx).into_any_element());

        div()
            .relative()
            .w_full()
            .flex_none()
            .child(
                div()
                    .absolute()
                    .top(px(-14.))
                    .left_0()
                    .right_0()
                    .h(px(14.))
                    .bg(linear_gradient(
                        180.,
                        linear_color_stop(lb.window.opacity(0.), 0.),
                        linear_color_stop(lb.window.opacity(0.7), 1.),
                    )),
            )
            .child(
                v_flex().w_full().items_center().bg(lb.window).child(
                    v_flex()
                        .w_full()
                        .max_w(metric::READING_MAX_WIDTH + metric::DETAIL_PADDING * 2.)
                        .px(metric::DETAIL_PADDING)
                        .pt(px(10.))
                        .pb(px(14.))
                        .gap(px(8.))
                        .children(rows),
                ),
            )
    }

    fn render_filter_chips(&self, cx: &mut Context<Self>) -> Option<Div> {
        if self.facet == Facet::All {
            return None;
        }
        Some(
            h_flex().gap(px(8.)).child(
                Button::new("ask-filter-result-type")
                    .outline()
                    .small()
                    .icon(Icon::new(Ico::CircleX))
                    .label(lokalbot_i18n::format(
                        "Results: {0}",
                        &[("0", lokalbot_i18n::tr(self.facet.label()).to_string())],
                    ))
                    .tooltip(lokalbot_i18n::tr("Clear the result-type filter"))
                    .on_click(cx.listener(|this, _, window, cx| {
                        this.facet = Facet::All;
                        this.scope_changed(window, cx);
                    })),
            ),
        )
    }

    /// "Answer sources: 3 meetings · 0 screen moments" with the list on demand.
    fn render_answer_sources(&self, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let count = self.results.meetings.len();
        let screens = self.results.screens.len();
        let label = if self.results.running {
            lokalbot_i18n::tr("Finding sources…").to_string()
        } else if count + screens > 0 {
            lokalbot_i18n::format(
                "Answer sources: {0} · {1}",
                &[
                    (
                        "0",
                        super::history::count_label(count, "meeting").to_string(),
                    ),
                    (
                        "1",
                        super::history::count_label(screens, "screen moment").to_string(),
                    ),
                ],
            )
        } else {
            lokalbot_i18n::format(
                "Answer sources: {0} · {1}",
                &[
                    ("0", self.sources.summary().to_string()),
                    ("1", self.date_scope.label().to_string()),
                ],
            )
        };
        let expanded = self.sources_expanded;
        let mut details: Vec<AnyElement> = Vec::new();
        if expanded {
            if count + screens > 0 {
                details.push(
                    div()
                        .text_color(lb.supporting)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr("The answer can retrieve passages from these meetings and screen moments, including collapsed matches. It may use only the passages relevant to your question.")))
                        .into_any_element(),
                );
                for group in &self.results.meetings {
                    let date = group
                        .meeting
                        .started_at
                        .with_timezone(&chrono::Local)
                        .format_localized(
                            lokalbot_i18n::date_pattern("%b %-d, %Y"),
                            lokalbot_i18n::date_locale(),
                        );
                    details.push(
                        div()
                            .truncate()
                            .text_color(lb.text_secondary)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                                "Meeting · {0} · {date}",
                                &[
                                    ("0", group.meeting.display_title().to_string()),
                                    ("date", format!("{}", date)),
                                ],
                            )))
                            .into_any_element(),
                    );
                }
                for screen in &self.results.screens {
                    let when = screen
                        .moment
                        .ts
                        .with_timezone(&chrono::Local)
                        .format_localized(
                            lokalbot_i18n::date_pattern("%b %-d, %Y at %-I:%M %p"),
                            lokalbot_i18n::date_locale(),
                        );
                    details.push(
                        div()
                            .truncate()
                            .text_color(lb.text_secondary)
                            .child(crate::ui::text::paragraph(lokalbot_i18n::format(
                                "Screen · {0} · {when} · {1}",
                                &[
                                    ("0", screen.moment.app.to_string()),
                                    ("when", format!("{}", when)),
                                    (
                                        "1",
                                        super::history::count_label(screen.captures, "moment")
                                            .to_string(),
                                    ),
                                ],
                            )))
                            .into_any_element(),
                    );
                }
            } else {
                let text = if self.meeting_scope.is_some() {
                    lokalbot_i18n::tr("Ask stays within the selected evidence shown above, even when this search has no matches.").to_string()
                } else {
                    lokalbot_i18n::format(
                        "Ask can search the selected sources within {0}. Result-type and screen-app filters apply to search results only.",
                        &[("0", self.date_scope.label().to_lowercase().to_string())],
                    )
                };
                details.push(
                    div()
                        .text_color(lb.supporting)
                        .child(text)
                        .into_any_element(),
                );
            }
        }
        v_flex()
            .gap(px(6.))
            .text_size(ty::SECONDARY)
            .child(
                h_flex()
                    .id("ask-answer-sources")
                    .gap(px(6.))
                    .items_center()
                    .cursor_pointer()
                    .text_color(lb.text_secondary)
                    .hover(|s| s.text_color(lb.text))
                    .child(ui::icon(
                        if expanded {
                            Ico::ChevronDown
                        } else {
                            Ico::ChevronRight
                        },
                        px(12.),
                        lb.text_secondary,
                    ))
                    .child(label)
                    .on_click(cx.listener(|this, _, _, cx| {
                        this.sources_expanded = !this.sources_expanded;
                        cx.notify();
                    })),
            )
            .when(expanded, |this| {
                this.child(
                    v_flex()
                        .id("ask-answer-sources-list")
                        .pl(px(18.))
                        .gap(px(4.))
                        .max_h(px(160.))
                        .overflow_y_scroll()
                        .children(details),
                )
            })
    }

    fn render_composer(&self, window: &mut Window, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let focused = self
            .composer
            .read(cx)
            .focus_handle(cx)
            .contains_focused(window, cx);
        let responding = self.is_responding(cx);
        let can_submit = !self.query.trim().is_empty() && !responding;
        let waiting = self.pending_question.is_some();
        let label = if waiting {
            lokalbot_i18n::tr("Waiting for sources…")
        } else if self.results.count() > 0 && !self.query.trim().is_empty() {
            lokalbot_i18n::tr("Ask about results")
        } else {
            lokalbot_i18n::tr("Ask")
        };

        v_flex()
            .w_full()
            .gap(px(12.))
            .px(px(10.))
            .pt(px(12.))
            .pb(px(12.))
            .rounded(metric::COMPOSER_RADIUS)
            .bg(lb.elevated)
            .border_1()
            .border_color(if focused {
                lb.accent_fill.opacity(0.45)
            } else {
                lb.separator
            })
            .shadow_sm()
            .child(
                Textarea::new(&self.composer)
                    .appearance(false)
                    .xsmall()
                    .text_size(ty::BODY)
                    .line_height(px(21.)),
            )
            .child(
                h_flex()
                    .gap(px(10.))
                    .items_center()
                    .px(px(4.))
                    .child(self.render_sources_menu(cx))
                    .child(self.render_date_scope(cx))
                    .child(div().flex_1().min_w_0())
                    .child(
                        h_flex()
                            .flex_none()
                            .gap(px(8.))
                            .justify_end()
                            .when(responding, |this| {
                                this.child(
                                    Button::new("ask-stop")
                                        .ghost()
                                        .icon(Icon::new(Ico::CircleStop))
                                        .tooltip(lokalbot_i18n::tr("Stop answering (Esc)"))
                                        .on_click(
                                            cx.listener(|this, _, _, cx| this.stop_answer(cx)),
                                        ),
                                )
                            })
                            .child(
                                Button::new("ask-submit")
                                    .primary()
                                    .icon(Icon::new(Ico::Sparkles))
                                    .label(label)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .disabled(!can_submit || waiting)
                                    .tooltip(lokalbot_i18n::tr(
                                        "Ask using the displayed results (Ctrl+Return)",
                                    ))
                                    .on_click(cx.listener(|this, _, window, cx| {
                                        this.submit(true, window, cx)
                                    })),
                            ),
                    ),
            )
    }

    fn render_sources_menu(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let page = cx.entity();
        let sources = self.sources;
        let facet = self.facet;
        Button::new("ask-sources")
            .ghost()
            .small()
            .label(sources.summary())
            .font_weight(FontWeight::SEMIBOLD)
            .dropdown_caret(true)
            .tooltip(lokalbot_i18n::tr("Choose sources and result filters"))
            .dropdown_menu(move |menu, window, cx| {
                let mut menu = menu.min_w(px(220.));
                for source in Source::ALL {
                    let page = page.clone();
                    let checked = sources.contains(source);
                    menu = menu.item(
                        PopupMenuItem::new(lokalbot_i18n::tr(source.label()))
                            .checked(checked)
                            .disabled(checked && sources.count() == 1)
                            .on_click(move |_, window, cx| {
                                page.update(cx, |page, cx| {
                                    page.sources.toggle(source);
                                    page.scope_changed(window, cx);
                                })
                            }),
                    );
                }
                let facet_page = page.clone();
                let facets = PopupMenu::build(window, cx, move |mut menu, _, _| {
                    for option in Facet::ALL {
                        let page = facet_page.clone();
                        menu = menu.item(
                            PopupMenuItem::new(lokalbot_i18n::tr(option.label()))
                                .checked(option == facet)
                                .on_click(move |_, window, cx| {
                                    page.update(cx, |page, cx| {
                                        page.facet = option;
                                        page.scope_changed(window, cx);
                                    })
                                }),
                        );
                    }
                    menu
                });
                let settings_page = page.clone();
                menu.separator()
                    .item(PopupMenuItem::submenu(
                        lokalbot_i18n::tr("Result type"),
                        facets,
                    ))
                    .separator()
                    .item(
                        PopupMenuItem::new(lokalbot_i18n::tr("Manage source permissions…"))
                            .on_click(move |_, _, cx| {
                                let data = settings_page.read(cx).data.clone();
                                data.update(cx, |data, cx| {
                                    data.open_settings(SettingsCategory::Privacy, cx)
                                });
                            }),
                    )
            })
    }

    fn render_date_scope(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let page = cx.entity();
        let current = self.date_scope;
        let picker = self.date_picker.clone();
        h_flex()
            .gap(px(4.))
            .items_center()
            .child(
                Popover::new("ask-date-scope")
                    .anchor(gpui_kit::Anchor::BottomLeft)
                    .trigger(
                        Button::new("ask-date-scope-button")
                            .outline()
                            .small()
                            .icon(Icon::new(Ico::Calendar))
                            .label(current.label())
                            .font_weight(FontWeight::SEMIBOLD)
                            .tooltip(lokalbot_i18n::tr("One date scope for meeting and screen search and answers")),
                    )
                    .content(move |_, _, cx| {
                        let lb = cx.lb().clone();
                        let popover = cx.entity();
                        let preset = |label: &'static str, scope: DateScope, cx: &App| {
                            let page = page.clone();
                            let popover = popover.clone();
                            let selected = scope == current;
                            let _ = cx;
                            Button::new(SharedString::from(format!("ask-date-{scope:?}")))
                                .outline()
                                .small()
                                .flex_1()
                                .min_w_0()
                                .icon(Icon::new(if selected { Ico::Check } else { Ico::Calendar }))
                                .label(label)
                                .on_click(move |_, window, cx| {
                                    page.update(cx, |page, cx| {
                                        page.date_scope = scope;
                                        page.scope_changed(window, cx);
                                    });
                                    popover.update(cx, |popover, cx| popover.dismiss(window, cx));
                                })
                        };
                        let use_page = page.clone();
                        let use_popover = popover.clone();
                        let calendar = picker.clone();
                        let picked_label = page.read(cx).picked_day.map(|day| {
                            day.format_localized(lokalbot_i18n::date_pattern("%b %-d, %Y"), lokalbot_i18n::date_locale()).to_string()
                        }).unwrap_or_else(|| lokalbot_i18n::tr("Select date").into());
                        v_flex()
                            .w(px(340.))
                            .gap(px(12.))
                            .p(px(4.))
                            .child(
                                div()
                                    .text_size(ty::SECTION)
                                    .font_weight(FontWeight::BOLD)
                                    .text_color(lb.text)
                                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Date scope"))),
                            )
                            .child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.supporting)
                                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Applies to search results and answers across all selected sources."))),
                            )
                            .child(
                                h_flex()
                                    .gap(px(8.))
                                    .child(preset(lokalbot_i18n::tr("Any time"), DateScope::AnyTime, cx))
                                    .child(preset(lokalbot_i18n::tr("Today"), DateScope::Today, cx)),
                            )
                            .child(
                                h_flex()
                                    .gap(px(8.))
                                    .child(preset(lokalbot_i18n::tr("Yesterday"), DateScope::Yesterday, cx))
                                    .child(preset(lokalbot_i18n::tr("Last 7 days"), DateScope::LastSevenDays, cx)),
                            )
                            .child(ui::divider(cx))
                            .child(
                                h_flex()
                                    .gap(px(8.))
                                    .items_center()
                                    .child(
                                        div()
                                            .flex_none()
                                            .text_size(ty::SECONDARY)
                                            .text_color(lb.text)
                                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Specific date"))),
                                    )
                                    .child(
                                        div()
                                            .flex_1()
                                            .min_w_0()
                                            .child(
                                                Popover::new("ask-specific-date")
                                                    .trigger(Button::new("ask-specific-date-button").outline().small().icon(Icon::new(Ico::Calendar)).label(picked_label))
                                                    .content(move |_, _, _| Calendar::new(&calendar).small().first_day_of_week(lokalbot_i18n::first_weekday())),
                                            ),
                                    )
                                    .child(
                                        Button::new("ask-date-use")
                                            .outline()
                                            .small()
                                            .label(lokalbot_i18n::tr("Use date"))
                                            .on_click(move |_, window, cx| {
                                                use_page.update(cx, |page, cx| {
                                                    if let Some(day) = page.picked_day {
                                                        page.date_scope = DateScope::Day(day);
                                                        page.scope_changed(window, cx);
                                                    }
                                                });
                                                use_popover.update(cx, |popover, cx| {
                                                    popover.dismiss(window, cx)
                                                });
                                            }),
                                    ),
                            )
                    }),
            )
            .when(current != DateScope::AnyTime, |this| {
                this.child(
                    Button::new("ask-date-clear")
                        .ghost()
                        .xsmall()
                        .icon(Icon::new(Ico::CircleX))
                        .tooltip(lokalbot_i18n::tr("Clear date filter"))
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.date_scope = DateScope::AnyTime;
                            this.scope_changed(window, cx);
                        })),
                )
            })
    }

    fn render_inference_status(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let lb = cx.lb().clone();
        let inference = inference(cx);
        let tint = if inference.blocked {
            lb.attention_text
        } else if inference.remote {
            lb.accent_text
        } else {
            lb.text_secondary
        };
        let help = if inference.remote {
            lokalbot_i18n::tr(
                "Answers send your question and selected evidence to the configured server. Open model settings.",
            )
        } else {
            lokalbot_i18n::tr(
                "Answers and selected evidence are processed on this PC. Open model settings.",
            )
        };
        h_flex().child(
            h_flex()
                .id("ask-inference-status")
                .gap(px(5.))
                .items_center()
                .min_h(px(24.))
                .cursor_pointer()
                .text_size(ty::SECONDARY)
                .text_color(if inference.remote || inference.blocked {
                    lb.text
                } else {
                    lb.text_secondary
                })
                .hover(|s| s.underline())
                .child(ui::icon(inference.icon, px(14.), tint))
                .child(inference.label)
                .tooltip(move |window, cx| {
                    gpui_kit::component::tooltip::Tooltip::new(help).build(window, cx)
                })
                .on_click(cx.listener(|this, _, _, cx| {
                    this.data.update(cx, |data, cx| {
                        data.open_settings(SettingsCategory::Models, cx)
                    });
                })),
        )
    }
}
