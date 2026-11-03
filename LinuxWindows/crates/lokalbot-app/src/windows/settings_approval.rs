//! The approval window (`SettingsApprovalView.swift`): one card for each terminal
//! request waiting for the person, listing every change it makes in full. Approve
//! applies exactly those changes through the same paths as Settings; Deny changes
//! nothing. Only this window can approve, and no key press does it.

use chrono::Utc;
use gpui_kit::component::button::{Button, ButtonVariant, ButtonVariants as _};
use gpui_kit::component::{Sizable as _, TitleBar, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, Bounds, Context, Entity, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, Render, SharedString, StatefulInteractiveElement as _,
    Styled as _, Subscription, Window, WindowBounds, WindowKind, WindowOptions, div, px, size,
};
use lokalbot_core::control::approvals::{ApprovalRequest, Subject};
use lokalbot_core::control::change::{ChangeClass, change_lines};
use lokalbot_core::retention::RetentionReview;

use crate::control::{self, ControlHost};
use crate::i18n::h_flex;
use crate::theme::{FONT_FAMILY, LbThemeExt as _, metric, ty};
use crate::ui::{self, Ico};

const WIDTH: f32 = 560.;
const HEIGHT: f32 = 480.;

/// Opens the window, or brings it forward.
pub fn open(cx: &mut App) {
    let existing = super::secondary(cx).settings_approval;
    if super::activate(existing, cx) {
        return;
    }
    let bounds = Bounds::centered(None, size(px(WIDTH), px(HEIGHT)), cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        kind: WindowKind::Normal,
        is_minimizable: false,
        app_id: Some(lokalbot_platform::APP_ID.into()),
        #[cfg(target_os = "linux")]
        window_decorations: Some(gpui_kit::WindowDecorations::Client),
        ..TitleBar::window_options()
    };
    match gpui_kit::open_window(options, cx, |window, cx| {
        window.set_window_title(lokalbot_i18n::tr("Approve Settings Change"));
        cx.new(|cx| SettingsApproval::new(window, cx))
    }) {
        Ok((handle, _)) => super::secondary(cx).settings_approval = Some(handle),
        Err(err) => log::error!("could not open the approval window: {err:#}"),
    }
}

pub struct SettingsApproval {
    host: Option<Entity<ControlHost>>,
    /// Whether this window has shown a request, so it can go with the last one.
    showed_request: bool,
    _subscriptions: Vec<Subscription>,
}

impl SettingsApproval {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let host = control::global(cx);
        let mut subscriptions = Vec::new();
        if let Some(host) = &host {
            subscriptions.push(cx.observe_in(host, window, |this, host, window, cx| {
                // The window goes away with the last request it was showing.
                let empty = host.read(cx).approvals.pending.is_empty();
                if this.showed_request && empty {
                    super::secondary(cx).settings_approval = None;
                    window.remove_window();
                    return;
                }
                this.showed_request |= !empty;
                cx.notify();
            }));
        }
        let showed_request = host
            .as_ref()
            .is_some_and(|host| !host.read(cx).approvals.pending.is_empty());
        Self {
            host,
            showed_request,
            _subscriptions: subscriptions,
        }
    }

    fn render_card(
        &self,
        index: usize,
        request: &ApprovalRequest,
        language: &str,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let _ = language;
        let lb = cx.lb().clone();
        let is_secret = request.is_secret();
        let seconds = (request.expires_at - Utc::now()).num_seconds().max(0);
        let remaining = format!("{}:{:02}", seconds / 60, seconds % 60);
        let line = if is_secret {
            lokalbot_i18n::tr("wants to save an API key in LokalBot.")
        } else {
            lokalbot_i18n::tr("wants to change LokalBot settings.")
        };
        let rows: Vec<AnyElement> = card_rows(request)
            .into_iter()
            .map(|row| {
                v_flex()
                    .gap(px(2.))
                    .child(
                        h_flex()
                            .gap(px(10.))
                            .items_start()
                            .child(ui::icon(
                                if row.widens {
                                    Ico::ShieldCheck
                                } else {
                                    Ico::SlidersHorizontal
                                },
                                px(15.),
                                if row.widens {
                                    lb.attention_text
                                } else {
                                    lb.text_secondary
                                },
                            ))
                            .child(
                                v_flex()
                                    .flex_1()
                                    .min_w_0()
                                    .gap(px(2.))
                                    .child(
                                        div()
                                            .text_size(ty::BODY)
                                            .text_color(lb.text)
                                            .child(ui::text::paragraph(row.title)),
                                    )
                                    .when_some(row.detail, |this, detail| {
                                        this.child(
                                            div()
                                                .text_size(ty::SECONDARY)
                                                .text_color(lb.text_secondary)
                                                .child(ui::text::paragraph(detail)),
                                        )
                                    })
                                    // Every value in full: this is what the person approves.
                                    .children(row.change.into_iter().map(|line| {
                                        div()
                                            .text_size(ty::SECONDARY)
                                            .text_color(lb.text)
                                            .child(ui::text::paragraph(line))
                                    })),
                            ),
                    )
                    .into_any_element()
            })
            .collect();
        let id = request.id;
        let deny_host = self.host.clone();
        let approve_host = self.host.clone();
        let cleanup = request.retention.is_some();
        v_flex()
            .id(("settings-approval-card", index))
            .w_full()
            .gap(px(14.))
            .child(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(ui::icon(Ico::Terminal, px(16.), lb.accent_text))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .truncate()
                            .text_size(ty::SECTION)
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(lb.text)
                            .child(SharedString::from(request.caller.clone())),
                    )
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text_secondary)
                            .child(remaining),
                    ),
            )
            .child(
                div()
                    .text_size(ty::BODY)
                    .text_color(lb.text)
                    .child(ui::text::paragraph(line)),
            )
            .child(v_flex().gap(px(10.)).children(rows))
            .when_some(request.retention.clone(), |this, review| {
                this.child(retention_lines(&review, cx))
            })
            .when_some(request.problem.clone(), |this, problem| {
                this.child(
                    div()
                        .text_size(ty::SECONDARY)
                        .text_color(lb.attention_text)
                        .child(ui::text::paragraph(problem)),
                )
            })
            .child(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(ui::text::paragraph(lokalbot_i18n::tr(
                        "Approve only what you asked your agent to do.",
                    ))),
            )
            .child(
                h_flex()
                    .gap(px(8.))
                    .items_center()
                    .child(div().flex_1())
                    .child(
                        Button::new(SharedString::from(format!(
                            "settings-approval-deny-{index}"
                        )))
                        .outline()
                        .label(lokalbot_i18n::tr("Deny"))
                        .on_click(move |_, _, cx| {
                            if let Some(host) = &deny_host {
                                host.update(cx, |host, cx| host.deny(id, cx));
                            }
                        }),
                    )
                    .child(
                        Button::new(SharedString::from(format!(
                            "settings-approval-approve-{index}"
                        )))
                        .with_variant(if cleanup {
                            ButtonVariant::Danger
                        } else {
                            ButtonVariant::Primary
                        })
                        .label(if cleanup {
                            lokalbot_i18n::tr("Approve and clean up")
                        } else {
                            lokalbot_i18n::tr("Approve")
                        })
                        .on_click(move |_, _, cx| {
                            if let Some(host) = &approve_host {
                                host.update(cx, |host, cx| host.approve(id, cx));
                            }
                        }),
                    ),
            )
            .into_any_element()
    }
}

struct CardRow {
    title: String,
    detail: Option<String>,
    change: Vec<String>,
    widens: bool,
}

fn card_rows(request: &ApprovalRequest) -> Vec<CardRow> {
    if let Subject::Secret(secret, _) = &request.subject {
        let change = request.changes.first();
        let field = |key: &str| {
            change
                .and_then(|c| c.get(key))
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string()
        };
        return vec![CardRow {
            title: lokalbot_i18n::tr(secret.title()).to_string(),
            detail: Some(lokalbot_i18n::tr(secret.summary()).to_string()),
            change: vec![format!("{} → {}", field("previous"), field("value"))],
            widens: true,
        }];
    }
    request
        .items
        .iter()
        .map(|item| {
            let widens = item.change == ChangeClass::Widening;
            CardRow {
                title: lokalbot_i18n::tr(item.spec.title).to_string(),
                detail: widens.then(|| lokalbot_i18n::tr(item.spec.summary).to_string()),
                change: change_lines(&item.spec, item.previous.as_ref(), item.stored.as_ref()),
                widens,
            }
        })
        .collect()
}

/// The same counts the retention review in Settings shows. Approving deletes
/// exactly this.
fn retention_lines(review: &RetentionReview, cx: &App) -> impl IntoElement + use<> {
    let lb = cx.lb().clone();
    let keep = if review.keep_text_forever {
        lokalbot_i18n::tr("Keep unsaved screen text and metadata indefinitely.")
    } else {
        lokalbot_i18n::tr(
            "Delete unsaved screen text, metadata, and search vectors on the same schedule.",
        )
    };
    let header = lokalbot_i18n::format(
        "Keep images and activity titles for {0} days. {1}",
        &[("0", review.days.to_string()), ("1", keep.to_string())],
    );
    let rows = [
        (lokalbot_i18n::tr("Images to remove"), review.pixel_count()),
        (
            lokalbot_i18n::tr("Text records to remove"),
            review.text_count(),
        ),
        (
            lokalbot_i18n::tr("Search vectors to remove"),
            review.vector_count(),
        ),
        (
            lokalbot_i18n::tr("Activity titles to clear"),
            review.activity_titles.len(),
        ),
        (
            lokalbot_i18n::tr("Saved moments preserved"),
            review.saved_count,
        ),
    ];
    v_flex()
        .gap(px(6.))
        .text_size(ty::SECONDARY)
        .text_color(lb.text)
        .child(ui::text::paragraph(header))
        .children(rows.into_iter().map(|(title, count)| {
            h_flex()
                .gap(px(28.))
                .child(div().flex_1().child(title))
                .child(count.to_string())
        }))
        .child(
            div()
                .text_color(lb.text_secondary)
                .child(ui::text::paragraph(lokalbot_i18n::tr("Cleanup cannot be undone. The policy stays unchanged until you apply this review. Failed deletions remain visible and can be retried."))),
        )
}

impl Render for SettingsApproval {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let lb = cx.lb().clone();
        let requests: Vec<ApprovalRequest> = self
            .host
            .as_ref()
            .map(|host| host.read(cx).approvals.pending.clone())
            .unwrap_or_default();
        let language = lokalbot_i18n::current().code;
        let cards: Vec<AnyElement> = requests
            .iter()
            .enumerate()
            .map(|(index, request)| {
                let card = self.render_card(index, request, language, cx);
                if index + 1 < requests.len() {
                    v_flex()
                        .gap(px(20.))
                        .child(card)
                        .child(ui::divider(cx))
                        .into_any_element()
                } else {
                    card
                }
            })
            .collect();
        v_flex()
            .size_full()
            .bg(lb.window)
            .text_color(lb.text)
            .font_family(FONT_FAMILY)
            .child(
                TitleBar::new().h(metric::TOOLBAR_HEIGHT).child(
                    div()
                        .pl(px(16.))
                        .text_size(ty::BODY)
                        .child(ui::text::paragraph(lokalbot_i18n::tr(
                            "Approve Settings Change",
                        ))),
                ),
            )
            .child(if cards.is_empty() {
                v_flex()
                    .flex_1()
                    .items_center()
                    .justify_center()
                    .gap(px(16.))
                    .child(ui::text::paragraph(lokalbot_i18n::tr(
                        "Nothing is waiting for your approval.",
                    )))
                    .child(
                        Button::new("settings-approval-close")
                            .small()
                            .outline()
                            .label(lokalbot_i18n::tr("Close"))
                            .on_click(|_, window, cx| {
                                super::secondary(cx).settings_approval = None;
                                window.remove_window();
                            }),
                    )
                    .into_any_element()
            } else {
                div()
                    .id("settings-approval-list")
                    .flex_1()
                    .min_h_0()
                    .overflow_y_scroll()
                    .p(px(24.))
                    .child(v_flex().gap(px(20.)).children(cards))
                    .into_any_element()
            })
    }
}
