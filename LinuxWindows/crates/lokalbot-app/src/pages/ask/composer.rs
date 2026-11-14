//! The field (`AskView.composerPanel`): screens attached as context, the
//! input, the two scope menus (sources, time), Ask or Stop, and a line under
//! it only when a remote or blocked model changes where the question goes.

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::calendar::Calendar;
use gpui_kit::component::input::Textarea;
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenu, PopupMenuItem};
use gpui_kit::component::popover::Popover;
use gpui_kit::component::{Disableable as _, Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, Div, ElementId, Focusable as _, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _,
    Window, div, px,
};
use lokalbot_core::settings::SummarizerBackend;

use super::AskPage;
use super::model::{self, PageKind};
use super::scope::{DateScope, Source};
use super::search::Facet;
use crate::state::SettingsCategory;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico, screen_thumbnail};

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
    /// The field and what belongs to it, at the reading width. On a new
    /// question it sits mid-page; in a conversation it is docked below the
    /// thread with a fade above it.
    pub(super) fn render_field_column(
        &mut self,
        page: PageKind,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Div {
        let lb = cx.lb().clone();
        let docked = page == PageKind::Conversation;
        let column = v_flex()
            .w_full()
            .max_w(metric::READING_MAX_WIDTH)
            .px(metric::DETAIL_PADDING)
            .when(docked, |this| this.pt(px(10.)).pb(px(14.)))
            .gap(px(8.))
            .when(!self.pins.is_empty(), |this| {
                this.child(self.render_pins(cx))
            })
            .child(self.render_composer(page, window, cx))
            .children(self.render_inference_status(cx));
        v_flex()
            .relative()
            .w_full()
            .flex_none()
            .items_center()
            .when(docked, |this| {
                this.child(
                    div()
                        .absolute()
                        .top(px(-14.))
                        .left_0()
                        .right_0()
                        .h(px(14.))
                        .bg(gpui_kit::linear_gradient(
                            180.,
                            gpui_kit::linear_color_stop(lb.page.opacity(0.), 0.),
                            gpui_kit::linear_color_stop(lb.page.opacity(0.7), 1.),
                        )),
                )
            })
            .child(column)
    }

    /// `pinnedContextRow`: the screens attached to the next question, each by
    /// its picture, with a way to take one or all off.
    fn render_pins(&self, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let mut row = h_flex().gap(px(8.)).items_center().flex_wrap().child(
            h_flex()
                .gap(px(5.))
                .items_center()
                .text_size(ty::SECONDARY)
                .font_weight(FontWeight::SEMIBOLD)
                .text_color(lb.text_secondary)
                .child(ui::icon(Ico::Pin, px(12.), lb.text_secondary))
                .child(lokalbot_i18n::tr("Context")),
        );
        for (index, pin) in self.pins.iter().enumerate() {
            let title = if pin.window_title.trim().is_empty() {
                pin.app.clone()
            } else {
                pin.window_title.clone()
            };
            let id = pin.id;
            let image = self.thumbnails.image(pin, cx, |page| &page.thumbnails);
            row = row.child(
                h_flex()
                    .gap(px(6.))
                    .items_center()
                    .p(px(4.))
                    .rounded(metric::ROW_RADIUS)
                    .bg(lb.chip_fill)
                    .child(screen_thumbnail::tile(image, pin, px(54.), px(34.), cx))
                    .child(
                        v_flex()
                            .max_w(px(160.))
                            .child(
                                div()
                                    .truncate()
                                    .text_size(ty::SECONDARY)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text)
                                    .child(title),
                            )
                            .child(
                                div()
                                    .text_size(ty::SECONDARY)
                                    .text_color(lb.text_secondary)
                                    .child(
                                        pin.ts
                                            .with_timezone(&chrono::Local)
                                            .format_localized(
                                                lokalbot_i18n::date_pattern("%-I:%M %p"),
                                                lokalbot_i18n::date_locale(),
                                            )
                                            .to_string(),
                                    ),
                            ),
                    )
                    .child(
                        Button::new(("ask-pin", index))
                            .ghost()
                            .xsmall()
                            .icon(Icon::new(Ico::CircleX))
                            .tooltip(lokalbot_i18n::tr("Remove this screen from the question"))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                this.pins.retain(|pin| pin.id != id);
                                cx.notify();
                            })),
                    ),
            );
        }
        row.child(div().text_size(ty::SECONDARY).child(ui::link(
            "ask-pins-clear",
            lokalbot_i18n::tr("Clear"),
            {
                let page = cx.entity();
                move |_, cx| {
                    page.update(cx, |page, cx| {
                        page.pins.clear();
                        cx.notify();
                    })
                }
            },
            cx,
        )))
    }

    fn render_composer(&self, page: PageKind, window: &mut Window, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let focused = self
            .composer
            .read(cx)
            .focus_handle(cx)
            .contains_focused(window, cx);
        let responding = self.is_responding(cx);
        let can_submit = !self.query.trim().is_empty() && !responding;
        let waiting = self.pending_question.is_some();
        let _ = page;
        let send = if responding {
            Button::new("ask-stop")
                .outline()
                .icon(Icon::new(Ico::Square))
                .label(lokalbot_i18n::tr("Stop"))
                .font_weight(FontWeight::SEMIBOLD)
                .tooltip(lokalbot_i18n::tr("Stop answering (Esc)"))
                .on_click(cx.listener(|this, _, _, cx| this.stop_answer(cx)))
                .into_any_element()
        } else {
            Button::new("ask-submit")
                .primary()
                .icon(Icon::new(Ico::ArrowUp))
                .label(lokalbot_i18n::tr("Ask"))
                .font_weight(FontWeight::SEMIBOLD)
                .disabled(!can_submit || waiting)
                .on_click(cx.listener(|this, _, window, cx| this.ask_about_results(window, cx)))
                .into_any_element()
        };
        v_flex()
            .w_full()
            .gap(px(10.))
            .pl(px(16.))
            .pr(px(12.))
            .pt(px(12.))
            .pb(px(10.))
            .rounded(px(16.))
            .bg(lb.panel)
            .border_1()
            .border_color(if focused {
                lb.accent_fill.opacity(0.6)
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
                    .w_full()
                    .gap(px(8.))
                    .items_center()
                    .flex_wrap()
                    .child(self.render_sources_menu(cx))
                    .child(self.render_time_menu(cx))
                    .child(div().flex_1().min_w(px(4.)))
                    .child(send),
            )
    }

    /// The bordered look of the two menus; one that limits the question (to
    /// earlier matches, a filter or dates) is tinted.
    fn menu_button(id: &'static str, label: String, highlighted: bool, cx: &App) -> Button {
        let lb = cx.lb();
        Button::new(id)
            .outline()
            .small()
            .label(label)
            .dropdown_caret(true)
            .when(highlighted, |this| {
                this.bg(lb.accent_wash)
                    .border_color(lb.accent_fill.opacity(0.35))
            })
    }

    /// Sources, their finer filters and the way to source permissions. When
    /// the question is limited to earlier matches or to evidence another page
    /// handed over, the button names that limit and the menu offers to widen it.
    fn render_sources_menu(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let page = cx.entity();
        let summary = self.scope_summary(cx);
        let sources = self.sources;
        let facet = self.facet;
        let offered = self.offered(cx);
        let has_pins = !self.pins.is_empty();
        let screen_app = self.screen_app.clone();
        let screen_apps = self.screen_apps.clone();
        let highlighted = summary.narrowed || summary.has_filters;
        Self::menu_button("ask-sources", summary.title.clone(), highlighted, cx)
            .tooltip(lokalbot_i18n::tr("Choose sources and result filters"))
            .dropdown_menu(move |menu, window, cx| {
                let mut menu = menu.min_w(px(220.));
                if let (Some(narrowed_to), Some(widen)) =
                    (summary.narrowed_to.clone(), summary.widen_title.clone())
                {
                    let widen_page = page.clone();
                    menu = menu
                        .item(
                            PopupMenuItem::new(model::mac("Only %@", &[&narrowed_to]))
                                .checked(true),
                        )
                        .item(PopupMenuItem::new(widen).on_click(move |_, window, cx| {
                            widen_page.update(cx, |page, cx| page.widen_sources(window, cx))
                        }))
                        .separator();
                }
                for source in Source::available(offered) {
                    let page = page.clone();
                    let checked = sources.contains(source);
                    menu = menu.item(
                        PopupMenuItem::new(source.label())
                            .checked(checked)
                            .disabled(
                                (checked && sources.count(offered) == 1)
                                    || (source == Source::Screen && has_pins),
                            )
                            .on_click(move |_, window, cx| {
                                page.update(cx, |page, cx| page.toggle_source(source, window, cx))
                            }),
                    );
                }
                let facet_page = page.clone();
                let facets = PopupMenu::build(window, cx, move |mut menu, _, _| {
                    for option in Facet::ALL.into_iter().filter(|option| match option {
                        Facet::Files => offered.files,
                        Facet::AgentNotes => offered.agent_notes,
                        _ => true,
                    }) {
                        let page = facet_page.clone();
                        menu = menu.item(
                            PopupMenuItem::new(option.label())
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
                let app_page = page.clone();
                let apps_selected = screen_app.clone();
                let apps_list = screen_apps.clone();
                let apps = PopupMenu::build(window, cx, move |mut menu, _, _| {
                    let all_page = app_page.clone();
                    menu = menu.item(
                        PopupMenuItem::new(lokalbot_i18n::tr("All apps"))
                            .checked(apps_selected.is_none())
                            .on_click(move |_, window, cx| {
                                all_page.update(cx, |page, cx| {
                                    page.screen_app = None;
                                    page.scope_changed(window, cx);
                                })
                            }),
                    );
                    for name in &apps_list {
                        let page = app_page.clone();
                        let chosen = name.clone();
                        menu = menu.item(
                            PopupMenuItem::new(SharedString::from(name.clone()))
                                .checked(apps_selected.as_deref() == Some(name.as_str()))
                                .on_click(move |_, window, cx| {
                                    let chosen = chosen.clone();
                                    page.update(cx, |page, cx| {
                                        page.screen_app = Some(chosen);
                                        page.scope_changed(window, cx);
                                    })
                                }),
                        );
                    }
                    menu
                });
                let menu = menu.separator().item(PopupMenuItem::submenu(
                    lokalbot_i18n::tr("Match type"),
                    facets,
                ));
                let menu = if sources.screen {
                    menu.item(PopupMenuItem::submenu(
                        lokalbot_i18n::tr("Screen app"),
                        apps,
                    ))
                } else {
                    menu
                };
                let settings_page = page.clone();
                menu.separator().item(
                    PopupMenuItem::new(lokalbot_i18n::tr("Source permissions…")).on_click(
                        move |_, _, cx| {
                            let data = settings_page.read(cx).data.clone();
                            data.update(cx, |data, cx| {
                                data.open_settings(SettingsCategory::Ask, cx)
                            });
                        },
                    ),
                )
            })
    }

    /// One date scope for search and answers across every source: Any time,
    /// Today, Yesterday, Last 7 days, a chosen day, and the way to choose one.
    fn render_time_menu(&self, cx: &mut Context<Self>) -> impl IntoElement + use<> {
        let page = cx.entity();
        let current = self.date_scope;
        let picker = self.date_picker.clone();
        let reset_page = page.clone();
        Popover::new("ask-time-scope")
            .anchor(gpui_kit::Anchor::TopLeft)
            .trigger(
                Self::menu_button(
                    "ask-time-scope-button",
                    current.label(),
                    current != DateScope::AnyTime,
                    cx,
                )
                .tooltip(lokalbot_i18n::tr(
                    "One date scope for meeting, activity, and screen search and answers",
                )),
            )
            .on_open_change(move |open, _, cx| {
                if !*open {
                    reset_page.update(cx, |page, cx| {
                        page.choosing_date = false;
                        cx.notify();
                    });
                }
            })
            .content(move |_, _, cx| {
                let lb = cx.lb().clone();
                let popover = cx.entity();
                let choosing = page.read(cx).choosing_date;
                let presets = [
                    ("Any time", DateScope::AnyTime),
                    ("Today", DateScope::Today),
                    ("Yesterday", DateScope::Yesterday),
                    ("Last 7 days", DateScope::LastSevenDays),
                ];
                let mut list = v_flex().min_w(px(220.)).gap(px(1.));
                for (key, scope) in presets {
                    let page = page.clone();
                    let popover = popover.clone();
                    list = list.child(time_row(
                        SharedString::from(format!("ask-time-{key}")),
                        lokalbot_i18n::tr(key).to_string(),
                        scope == current,
                        move |window, cx| {
                            page.update(cx, |page, cx| {
                                page.date_scope = scope;
                                page.scope_changed(window, cx);
                            });
                            popover.update(cx, |popover, cx| popover.dismiss(window, cx));
                        },
                        &lb,
                    ));
                }
                if !matches!(
                    current,
                    DateScope::AnyTime
                        | DateScope::Today
                        | DateScope::Yesterday
                        | DateScope::LastSevenDays
                ) {
                    list = list.child(time_row(
                        "ask-time-custom".into(),
                        current.label(),
                        true,
                        |_, _| {},
                        &lb,
                    ));
                }
                let choose_page = page.clone();
                list = list
                    .child(div().my(px(4.)).h(px(1.)).bg(lb.separator))
                    .child(time_row(
                        "ask-time-choose".into(),
                        lokalbot_i18n::tr("Choose a date…").to_string(),
                        false,
                        move |_, cx| {
                            choose_page.update(cx, |page, cx| {
                                page.choosing_date = !page.choosing_date;
                                cx.notify();
                            })
                        },
                        &lb,
                    ));
                if choosing {
                    let calendar = picker.clone();
                    let use_page = page.clone();
                    let use_popover = popover.clone();
                    let picked_label = page
                        .read(cx)
                        .picked_day
                        .map(|day| {
                            day.format_localized(
                                lokalbot_i18n::date_pattern("%b %-d, %Y"),
                                lokalbot_i18n::date_locale(),
                            )
                            .to_string()
                        })
                        .unwrap_or_else(|| lokalbot_i18n::tr("Specific date").into());
                    list = list.child(
                        h_flex()
                            .gap(px(8.))
                            .items_center()
                            .px(px(8.))
                            .pt(px(6.))
                            .pb(px(4.))
                            .child(
                                div().flex_1().min_w_0().child(
                                    Popover::new("ask-specific-date")
                                        .trigger(
                                            Button::new("ask-specific-date-button")
                                                .outline()
                                                .small()
                                                .icon(Icon::new(Ico::Calendar))
                                                .label(picked_label),
                                        )
                                        .content(move |_, _, _| {
                                            Calendar::new(&calendar)
                                                .small()
                                                .first_day_of_week(lokalbot_i18n::first_weekday())
                                        }),
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
                                                page.choosing_date = false;
                                                page.scope_changed(window, cx);
                                            }
                                        });
                                        use_popover
                                            .update(cx, |popover, cx| popover.dismiss(window, cx));
                                    }),
                            ),
                    );
                }
                list
            })
    }

    /// Shown only when it changes where the question goes: a remote model, or
    /// a model connection that is blocked.
    fn render_inference_status(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let inference = inference(cx);
        if !inference.remote && !inference.blocked {
            return None;
        }
        let lb = cx.lb().clone();
        let tint = if inference.blocked {
            lb.attention_text
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
        Some(
            h_flex()
                .child(
                    h_flex()
                        .id("ask-inference-status")
                        .gap(px(6.))
                        .items_center()
                        .min_h(px(22.))
                        .pl(px(6.))
                        .cursor_pointer()
                        .text_size(ty::SECONDARY)
                        .text_color(tint)
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
                .into_any_element(),
        )
    }
}

/// One row of the time menu: a check when it is the chosen scope, then its name.
fn time_row(
    id: SharedString,
    label: String,
    checked: bool,
    on_click: impl Fn(&mut Window, &mut App) + 'static,
    lb: &crate::theme::Palette,
) -> gpui_kit::Stateful<Div> {
    let hover = lb.hover;
    h_flex()
        .id(ElementId::Name(id))
        .w_full()
        .gap(px(8.))
        .items_center()
        .px(px(8.))
        .py(px(5.))
        .rounded(px(6.))
        .cursor_pointer()
        .hover(move |style| style.bg(hover))
        .text_size(ty::SECONDARY)
        .text_color(lb.text)
        .child(div().w(px(14.)).flex_none().when(checked, |this| {
            this.child(ui::icon(Ico::Check, px(14.), lb.text))
        }))
        .child(label)
        .on_click(move |_, window, cx| on_click(window, cx))
}
