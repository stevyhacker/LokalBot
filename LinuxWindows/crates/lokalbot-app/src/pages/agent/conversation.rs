//! The conversation (`AgentSessionView.swift`): task header, find bar,
//! transcript with activity groups and responses, the approval dock and the
//! composer.

use std::borrow::Cow;
use std::collections::hash_map::DefaultHasher;
use std::hash::{Hash as _, Hasher as _};
use std::rc::Rc;

use crate::i18n::h_flex;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::input::Input;
use gpui_kit::component::menu::{DropdownMenu as _, PopupMenuItem};
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::{Icon, Sizable as _, v_flex};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, Context, Div, FontWeight, Hsla, InteractiveElement as _, IntoElement,
    ParentElement as _, SharedString, StatefulInteractiveElement as _, Styled as _, Window, div,
    px, relative,
};
use uuid::Uuid;

use lokalbot_agent::tasks::{AttachmentKind, ResultPreview, TranscriptGroup, activity_summary};
use lokalbot_agent::transcript::ApprovalRequest;
use lokalbot_agent::{RecoveryAction, SessionState, ToolStatus, TranscriptItem};

use super::{AgentPage, small_icon_button};
use crate::state::SettingsCategory;
use crate::theme::{LbThemeExt as _, metric, ty};
use crate::ui::answer_text::{self, Answer, AnswerStyle};
use crate::ui::citations::CitationSource;
use crate::ui::{self, Ico};

/// What the conversation shows for the selected task, copied out of the
/// model so rendering can borrow the page mutably.
pub(super) struct Snapshot {
    pub task: Uuid,
    pub title: String,
    pub status: &'static str,
    pub state: SessionState,
    pub items: Vec<TranscriptItem>,
    pub approvals: Vec<ApprovalRequest>,
    pub can_allow_first: bool,
    pub recovery: Option<RecoveryAction>,
    pub has_failed_prompt: bool,
    pub archived: bool,
    pub can_branch: bool,
}

const STARTERS: [(&str, &str, Ico); 3] = [
    (
        "Draft follow-up",
        "Draft a follow-up from my most recent meeting. Do not send it.",
        Ico::CornerDownRight,
    ),
    (
        "Prepare stand-up",
        "Prepare a concise stand-up update from my recent meetings and open actions.",
        Ico::Users,
    ),
    (
        "Export actions",
        "Prepare a local Markdown export of my open meeting actions. Show me the plan before writing files.",
        Ico::Share,
    ),
];

impl AgentPage {
    pub(super) fn snapshot(&self, cx: &App) -> Option<Snapshot> {
        let tasks = self.model(cx)?.tasks.as_ref()?;
        let tab = tasks.selected()?;
        let session = &tab.session;
        let approvals: Vec<ApprovalRequest> =
            session.pending_approvals().into_iter().cloned().collect();
        let busy = matches!(
            session.state,
            SessionState::Running | SessionState::Starting
        ) || session.is_sending;
        Some(Snapshot {
            task: tab.id,
            title: tab.title(),
            status: session.task_status(),
            state: session.state.clone(),
            items: session.items().to_vec(),
            can_allow_first: approvals
                .first()
                .is_some_and(|r| session.can_allow_for_session(r)),
            approvals,
            recovery: session.recovery_action,
            has_failed_prompt: session.failed_prompt.is_some(),
            archived: tab.record.is_archived,
            can_branch: !busy
                && (session.active_session_file.is_some() || tab.record.session_file.is_some()),
        })
    }

    pub(super) fn render_conversation(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let Some(snapshot) = self.snapshot(cx) else {
            return div().into_any_element();
        };
        let lb = cx.lb().clone();
        let header = v_flex()
            .w_full()
            .max_w(metric::READING_MAX_WIDTH)
            .gap(px(6.))
            .child(
                div()
                    .line_clamp(2)
                    .text_size(px(22.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text)
                    .child(snapshot.title.clone()),
            )
            .child(
                div()
                    .text_size(ty::SECONDARY)
                    .text_color(lb.text_secondary)
                    .child(snapshot.status),
            );
        let approval = snapshot
            .approvals
            .first()
            .cloned()
            .map(|request| self.render_approval_dock(&request, &snapshot, window, cx));
        v_flex()
            .size_full()
            .child(
                h_flex()
                    .w_full()
                    .justify_center()
                    .px(px(20.))
                    .pt(px(20.))
                    .pb(px(16.))
                    .child(header),
            )
            .when(self.find_visible, |this| {
                this.child(self.render_find_bar(&snapshot, cx))
            })
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .child(self.render_transcript(&snapshot, window, cx)),
            )
            .when_some(approval, |this, dock| {
                this.child(
                    h_flex()
                        .w_full()
                        .justify_center()
                        .px(px(20.))
                        .pb(px(8.))
                        .child(dock),
                )
            })
            .child(self.render_composer(&snapshot, window, cx))
            .into_any_element()
    }

    // ------------------------------------------------------------ find

    /// Group ids whose text contains the find query.
    fn matches(&self, items: &[TranscriptItem]) -> Vec<String> {
        let query = self.find_query.trim().to_lowercase();
        if query.is_empty() {
            return Vec::new();
        }
        TranscriptGroup::make(items)
            .into_iter()
            .filter(|group| {
                group
                    .items
                    .iter()
                    .any(|item| item.searchable_text().to_lowercase().contains(&query))
            })
            .map(|group| group.id)
            .collect()
    }

    pub(super) fn scroll_to_match(&mut self, cx: &mut Context<Self>) {
        let Some(snapshot) = self.snapshot(cx) else {
            return;
        };
        let matches = self.matches(&snapshot.items);
        let Some(target) = matches.get(self.match_index) else {
            return;
        };
        let groups = TranscriptGroup::make(&snapshot.items);
        if let Some(index) = groups.iter().position(|g| &g.id == target) {
            let offset = self.transcript_offset(&snapshot);
            self.transcript_scroll.scroll_to_item(index + offset);
            if groups[index].is_activity() {
                self.expanded_groups.insert(target.clone());
            }
        }
    }

    pub(super) fn next_match(&mut self, step: isize, cx: &mut Context<Self>) {
        let Some(snapshot) = self.snapshot(cx) else {
            return;
        };
        let count = self.matches(&snapshot.items).len() as isize;
        if count == 0 {
            return;
        }
        self.match_index =
            ((self.match_index as isize + step) % count + count) as usize % count as usize;
        self.follow_output = false;
        self.scroll_to_match(cx);
        cx.notify();
    }

    fn render_find_bar(&self, snapshot: &Snapshot, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let count = self.matches(&snapshot.items).len();
        let label = if count == 0 {
            lokalbot_i18n::tr("0 matches").to_string()
        } else {
            lokalbot_i18n::format(
                "{0} of {count}",
                &[
                    ("0", format!("{}", self.match_index.min(count - 1) + 1)),
                    ("count", format!("{}", count)),
                ],
            )
        };
        h_flex()
            .w_full()
            .justify_center()
            .px(px(20.))
            .pb(px(8.))
            .child(
                h_flex()
                    .w_full()
                    .max_w(metric::READING_MAX_WIDTH)
                    .gap(px(8.))
                    .items_center()
                    .child(
                        div().flex_1().child(
                            Input::new(&self.find_input)
                                .small()
                                .cleanable(true)
                                .prefix(ui::icon(Ico::Search, px(13.), lb.text_secondary)),
                        ),
                    )
                    .child(
                        div()
                            .text_size(ty::CAPTION)
                            .text_color(lb.text_secondary)
                            .child(label),
                    )
                    .child(
                        small_icon_button(
                            "agent-find-previous",
                            Ico::ChevronUp,
                            lokalbot_i18n::tr("Previous match"),
                        )
                        .on_click(cx.listener(|this, _, _, cx| this.next_match(-1, cx))),
                    )
                    .child(
                        small_icon_button(
                            "agent-find-next",
                            Ico::ChevronDown,
                            lokalbot_i18n::tr("Next match"),
                        )
                        .on_click(cx.listener(|this, _, _, cx| this.next_match(1, cx))),
                    )
                    .child(
                        small_icon_button(
                            "agent-find-close",
                            Ico::X,
                            lokalbot_i18n::tr("Close find"),
                        )
                        .on_click(cx.listener(|this, _, window, cx| {
                            this.find_visible = false;
                            this.find_query.clear();
                            this.find_input
                                .update(cx, |state, cx| state.set_value("", window, cx));
                            cx.notify();
                        })),
                    ),
            )
    }

    // ------------------------------------------------------- transcript

    /// Children of the scroll container before the first group.
    fn transcript_offset(&self, snapshot: &Snapshot) -> usize {
        usize::from(snapshot.items.is_empty())
            + usize::from(matches!(snapshot.state, SessionState::Failed(_)))
    }

    fn render_transcript(
        &mut self,
        snapshot: &Snapshot,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let groups = TranscriptGroup::make(&snapshot.items);
        let matches = self.matches(&snapshot.items);
        let current = matches.get(self.match_index).cloned();
        let first_id = snapshot.items.first().map(|i| i.id().to_string());
        let mut rows: Vec<AnyElement> = Vec::new();
        if snapshot.items.is_empty() {
            rows.push(centered(self.render_empty_state(cx).into_any_element()));
        }
        if let SessionState::Failed(message) = &snapshot.state {
            rows.push(centered(
                self.render_recovery(message, snapshot, cx)
                    .into_any_element(),
            ));
        }
        for group in &groups {
            let highlighted = current.as_deref() == Some(group.id.as_str());
            let element = if group.is_activity() {
                self.render_activity_group(group, cx).into_any_element()
            } else if let Some(item) = group.items.first() {
                self.render_message(item, first_id.as_deref() == Some(item.id()), snapshot, cx)
            } else {
                continue;
            };
            rows.push(centered(
                div()
                    .w_full()
                    .rounded(metric::GROUP_RADIUS)
                    .when(highlighted, |this| {
                        this.border_1().border_color(lb.accent_fill.opacity(0.6))
                    })
                    .child(element)
                    .into_any_element(),
            ));
        }
        rows.push(div().h(px(24.)).into_any_element());
        let near_end = {
            let offset = self.transcript_scroll.offset();
            let max = self.transcript_scroll.max_offset();
            max.y + offset.y < px(120.)
        };
        let show_jump = !self.follow_output && !near_end && !snapshot.items.is_empty();
        div()
            .relative()
            .size_full()
            .child(
                div()
                    .id("agent-transcript")
                    .size_full()
                    .overflow_y_scroll()
                    .track_scroll(&self.transcript_scroll)
                    .on_scroll_wheel(cx.listener(|this, _, _, cx| {
                        let offset = this.transcript_scroll.offset();
                        let max = this.transcript_scroll.max_offset();
                        this.follow_output = max.y + offset.y < px(120.);
                        cx.notify();
                    }))
                    .px(px(20.))
                    .pt(px(4.))
                    .flex()
                    .flex_col()
                    .gap(px(12.))
                    .children(rows),
            )
            .when(show_jump, |this| {
                this.child(
                    h_flex().absolute().bottom(px(12.)).right(px(16.)).child(
                        Button::new("agent-jump-latest")
                            .outline()
                            .small()
                            .icon(Icon::new(Ico::ArrowDown))
                            .label(lokalbot_i18n::tr("Jump to latest"))
                            .bg(lb.elevated)
                            .shadow_md()
                            .on_click(cx.listener(|this, _, _, cx| {
                                this.follow_output = true;
                                this.transcript_scroll.scroll_to_bottom();
                                cx.notify();
                            })),
                    ),
                )
            })
            .into_any_element()
    }

    fn render_empty_state(&mut self, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let mut starters = h_flex().flex_wrap().gap(px(12.));
        for (index, (title, prompt, icon)) in STARTERS.iter().enumerate() {
            let prompt = prompt.to_string();
            starters = starters.child(
                Button::new(("agent-starter", index as u64))
                    .outline()
                    .icon(Icon::new(*icon))
                    .label(lokalbot_i18n::tr(title))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        let prompt = prompt.clone();
                        this.with_session(cx, |session| session.draft = prompt);
                        this.sync_composer(window, cx);
                        this.focus_composer(window, cx);
                    })),
            );
        }
        v_flex()
            .w_full()
            .gap(px(20.))
            .py(px(24.))
            .child(
                div()
                    .text_size(px(22.))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "What would you like to work on?",
                    ))),
            )
            .child(
                div()
                    .text_size(ty::BODY)
                    .text_color(lb.text_secondary)
                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                        "Start with your work memory or a file. The agent starts when you send.",
                    ))),
            )
            .child(starters)
    }

    fn render_recovery(
        &mut self,
        message: &str,
        snapshot: &Snapshot,
        cx: &mut Context<Self>,
    ) -> Div {
        let lb = cx.lb().clone();
        let data = self.data.clone();
        let task = snapshot.task;
        ui::status_surface(lb.attention, cx)
            .w_full()
            .p(px(14.))
            .child(
                v_flex()
                    .gap(px(10.))
                    .child(
                        h_flex()
                            .gap(px(8.))
                            .items_center()
                            .child(ui::icon(Ico::TriangleAlert, px(15.), lb.attention_text))
                            .child(
                                div()
                                    .text_size(ty::SECTION)
                                    .font_weight(FontWeight::SEMIBOLD)
                                    .text_color(lb.text)
                                    .child(crate::ui::text::paragraph(lokalbot_i18n::tr(
                                        "Task needs attention",
                                    ))),
                            ),
                    )
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text)
                            .child(message.to_string()),
                    )
                    .child(
                        h_flex()
                            .gap(px(8.))
                            .when(
                                snapshot.recovery == Some(RecoveryAction::OpenModels),
                                |this| {
                                    this.child(
                                        Button::new("agent-open-models")
                                            .outline()
                                            .small()
                                            .label(lokalbot_i18n::tr("Open Models"))
                                            .on_click(move |_, _, cx| {
                                                data.update(cx, |data, cx| {
                                                    data.open_settings(SettingsCategory::Models, cx)
                                                })
                                            }),
                                    )
                                },
                            )
                            .child(
                                Button::new("agent-restart")
                                    .outline()
                                    .small()
                                    .label(lokalbot_i18n::tr("Reconnect"))
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.with_tasks(cx, |tasks| {
                                            tasks.start(task);
                                        })
                                    })),
                            )
                            .when(snapshot.has_failed_prompt, |this| {
                                this.child(
                                    Button::new("agent-review-retry")
                                        .outline()
                                        .small()
                                        .label(lokalbot_i18n::tr("Review & retry"))
                                        .on_click(cx.listener(|this, _, window, cx| {
                                            this.with_session(cx, |s| s.review_retry());
                                            this.sync_composer(window, cx);
                                            this.focus_composer(window, cx);
                                        })),
                                )
                            }),
                    ),
            )
    }

    fn render_message(
        &mut self,
        item: &TranscriptItem,
        is_first: bool,
        snapshot: &Snapshot,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let lb = cx.lb().clone();
        let size = px(self.text_size);
        match item {
            TranscriptItem::User { id, text } => {
                let copy_key = format!("user-{id}");
                let copied = self.copied.as_deref() == Some(copy_key.as_str());
                let page = cx.entity();
                let item_id = id.clone();
                let branch_id = id.clone();
                let can_branch = snapshot.can_branch;
                let task = snapshot.task;
                let text_for_copy = text.clone();
                v_flex()
                    .w_full()
                    .items_end()
                    .gap(px(8.))
                    .pb(px(12.))
                    .when(!is_first, |this| {
                        this.child(
                            div()
                                .w_full()
                                .pt(px(12.))
                                .pb(px(16.))
                                .child(ui::divider(cx)),
                        )
                    })
                    .child(
                        div()
                            .max_w(relative(0.85))
                            .p(px(12.))
                            .rounded(metric::GROUP_RADIUS)
                            .bg(lb.group_fill)
                            .border_1()
                            .border_color(lb.group_stroke)
                            .text_size(size)
                            .line_height(size * 1.45)
                            .text_color(lb.text)
                            .child(text.clone()),
                    )
                    .child(
                        h_flex()
                            .gap(px(4.))
                            .child(
                                Button::new(SharedString::from(format!("agent-copy-{id}")))
                                    .ghost()
                                    .xsmall()
                                    .icon(Icon::new(if copied { Ico::Check } else { Ico::Copy }))
                                    .label(if copied {
                                        lokalbot_i18n::tr("Copied")
                                    } else {
                                        lokalbot_i18n::tr("Copy")
                                    })
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.copy(copy_key.clone(), text_for_copy.clone(), cx)
                                    })),
                            )
                            .child(
                                Button::new(SharedString::from(format!("agent-user-more-{id}")))
                                    .ghost()
                                    .xsmall()
                                    .icon(Icon::new(Ico::Ellipsis))
                                    .tooltip(lokalbot_i18n::tr("More message actions"))
                                    .dropdown_menu(move |menu, _, _| {
                                        let edit = page.clone();
                                        let branch = page.clone();
                                        let item_id = item_id.clone();
                                        let branch_id = branch_id.clone();
                                        menu.item(
                                            PopupMenuItem::new(lokalbot_i18n::tr(
                                                "Edit as follow-up",
                                            ))
                                            .on_click(move |_, window, cx| {
                                                let item_id = item_id.clone();
                                                edit.update(cx, |page, cx| {
                                                    page.with_session(cx, |s| {
                                                        s.edit_as_follow_up(&item_id)
                                                    });
                                                    page.sync_composer(window, cx);
                                                    page.focus_composer(window, cx);
                                                })
                                            }),
                                        )
                                        .item(
                                            PopupMenuItem::new(lokalbot_i18n::tr(
                                                "Branch from here",
                                            ))
                                            .disabled(!can_branch)
                                            .on_click(move |_, _, cx| {
                                                let branch_id = branch_id.clone();
                                                branch.update(cx, |page, cx| {
                                                    page.with_tasks(cx, |tasks| {
                                                        tasks.fork(task, &branch_id)
                                                    })
                                                })
                                            }),
                                        )
                                    }),
                            ),
                    )
                    .into_any_element()
            }
            TranscriptItem::Assistant {
                id,
                text,
                is_streaming,
            } => {
                if *is_streaming {
                    return div()
                        .w_full()
                        .text_size(size)
                        .line_height(size * 1.5)
                        .text_color(lb.text)
                        .child(text.clone())
                        .into_any_element();
                }
                let answer = self.parsed_answer(id, text);
                let style = AnswerStyle {
                    size,
                    line_height: size * 1.5,
                    color: lb.text,
                };
                let citations = answer.citations.clone();
                let cite_page = cx.entity();
                let on_cite: answer_text::CiteHandler = Rc::new(move |index, _, cx| {
                    if let Some(source) = citations.get(index).cloned() {
                        cite_page.update(cx, |page, cx| page.open_cited_source(&source, cx));
                    }
                });
                let copy_key = format!("assistant-{id}");
                let copied = self.copied.as_deref() == Some(copy_key.as_str());
                let page = cx.entity();
                let retry_id = id.clone();
                let more_id = id.clone();
                let text_for_copy = text.clone();
                let text_for_results = text.clone();
                let can_branch = snapshot.can_branch;
                let task = snapshot.task;
                v_flex()
                    .w_full()
                    .gap(px(10.))
                    .child(answer_text::render(
                        SharedString::from(format!("agent-answer-{id}")),
                        &answer,
                        style,
                        on_cite,
                        cx,
                    ))
                    .child(
                        h_flex()
                            .gap(px(4.))
                            .child(
                                Button::new(SharedString::from(format!("agent-copy-{id}")))
                                    .ghost()
                                    .xsmall()
                                    .icon(Icon::new(if copied { Ico::Check } else { Ico::Copy }))
                                    .label(if copied {
                                        lokalbot_i18n::tr("Copied")
                                    } else {
                                        lokalbot_i18n::tr("Copy")
                                    })
                                    .on_click(cx.listener(move |this, _, _, cx| {
                                        this.copy(copy_key.clone(), text_for_copy.clone(), cx)
                                    })),
                            )
                            .child(
                                Button::new(SharedString::from(format!("agent-retry-{id}")))
                                    .ghost()
                                    .xsmall()
                                    .icon(Icon::new(Ico::RotateCcw))
                                    .label(lokalbot_i18n::tr("Retry response"))
                                    .on_click(cx.listener(move |this, _, window, cx| {
                                        let retry_id = retry_id.clone();
                                        this.with_session(cx, |s| {
                                            s.review_response_retry(&retry_id)
                                        });
                                        this.sync_composer(window, cx);
                                        this.focus_composer(window, cx);
                                    })),
                            )
                            .child(
                                Button::new(SharedString::from(format!("agent-answer-more-{id}")))
                                    .ghost()
                                    .xsmall()
                                    .icon(Icon::new(Ico::Ellipsis))
                                    .tooltip(lokalbot_i18n::tr("More response actions"))
                                    .dropdown_menu(move |menu, _, _| {
                                        let open = page.clone();
                                        let branch = page.clone();
                                        let text = text_for_results.clone();
                                        let more_id = more_id.clone();
                                        let branch_id = more_id.clone();
                                        menu.item(
                                            PopupMenuItem::new(lokalbot_i18n::tr(
                                                "Open in results",
                                            ))
                                            .on_click(move |_, _, cx| {
                                                let preview = ResultPreview {
                                                    id: more_id.clone(),
                                                    title: lokalbot_i18n::tr("Agent response")
                                                        .into(),
                                                    detail: lokalbot_i18n::tr(
                                                        "Conversation result",
                                                    )
                                                    .into(),
                                                    text: text.clone(),
                                                    original: None,
                                                    proposed: None,
                                                    file_path: None,
                                                };
                                                open.update(cx, |page, cx| {
                                                    page.show_preview(preview, cx)
                                                })
                                            }),
                                        )
                                        .item(
                                            PopupMenuItem::new(lokalbot_i18n::tr(
                                                "Branch from here",
                                            ))
                                            .disabled(!can_branch)
                                            .on_click(move |_, _, cx| {
                                                let branch_id = branch_id.clone();
                                                branch.update(cx, |page, cx| {
                                                    page.with_tasks(cx, |tasks| {
                                                        tasks.fork(task, &branch_id)
                                                    })
                                                })
                                            }),
                                        )
                                    }),
                            ),
                    )
                    .into_any_element()
            }
            TranscriptItem::Notice { text, is_error, .. } => {
                let tint: Hsla = if *is_error {
                    lb.attention_text
                } else {
                    lb.text_secondary
                };
                h_flex()
                    .w_full()
                    .gap(px(8.))
                    .items_start()
                    .child(div().pt(px(2.)).child(ui::icon(
                        if *is_error {
                            Ico::TriangleAlert
                        } else {
                            Ico::Info
                        },
                        px(14.),
                        tint,
                    )))
                    .child(
                        div()
                            .flex_1()
                            .min_w_0()
                            .text_size(ty::SECONDARY)
                            .text_color(tint)
                            .child(text.clone()),
                    )
                    .into_any_element()
            }
            _ => div().into_any_element(),
        }
    }

    fn parsed_answer(&mut self, id: &str, text: &str) -> Rc<Answer> {
        let mut hasher = DefaultHasher::new();
        text.hash(&mut hasher);
        let hash = hasher.finish();
        if let Some((cached, answer)) = self.answers.get(id)
            && *cached == hash
        {
            return answer.clone();
        }
        let answer = Rc::new(answer_text::parse(&cite_sources(text)));
        self.answers.insert(id.to_string(), (hash, answer.clone()));
        answer
    }

    /// A numbered reference opens its attached source beside the task, as
    /// source links in macOS answers do; references to anything else do
    /// nothing.
    fn open_cited_source(&mut self, source: &CitationSource, cx: &mut Context<Self>) {
        let attachment = self
            .model(cx)
            .and_then(|m| m.tasks.as_ref()?.selected())
            .and_then(|tab| {
                tab.session
                    .source_attachments
                    .iter()
                    .find(|a| match source {
                        CitationSource::Meeting { id, .. } => {
                            a.kind == AttachmentKind::Meeting
                                && a.reference.to_lowercase().starts_with(&id.to_lowercase())
                        }
                        CitationSource::Screen { snapshot_id } => {
                            a.kind == AttachmentKind::Moment
                                && a.reference == snapshot_id.to_string()
                        }
                    })
                    .cloned()
            });
        if let Some(attachment) = attachment {
            self.preview_source(&attachment, cx);
        }
    }

    // --------------------------------------------------------- activity

    fn render_activity_group(&mut self, group: &TranscriptGroup, cx: &mut Context<Self>) -> Div {
        let lb = cx.lb().clone();
        let expanded = self.expanded_groups.contains(&group.id);
        let running = group.is_running();
        let failed = group.has_failure();
        let group_id = group.id.clone();
        let status: AnyElement = if running {
            Spinner::new()
                .xsmall()
                .color(lb.text_secondary)
                .into_any_element()
        } else {
            ui::icon(
                if failed {
                    Ico::CircleAlert
                } else {
                    Ico::CircleCheck
                },
                px(14.),
                if failed {
                    lb.attention_text
                } else {
                    lb.text_secondary
                },
            )
            .into_any_element()
        };
        let header = h_flex()
            .id(SharedString::from(format!("agent-activity-{}", group.id)))
            .gap(px(8.))
            .items_center()
            .cursor_pointer()
            .child(status)
            .child(
                div()
                    .text_size(ty::SECONDARY)
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(lb.text)
                    .child(group.summary()),
            )
            .when(running, |this| {
                this.child(
                    div()
                        .text_size(ty::CAPTION)
                        .text_color(lb.text_secondary)
                        .child(crate::ui::text::paragraph(lokalbot_i18n::tr("In progress"))),
                )
            })
            .child(div().flex_1())
            .child(ui::icon(
                if expanded {
                    Ico::ChevronDown
                } else {
                    Ico::ChevronRight
                },
                px(12.),
                lb.text_secondary,
            ))
            .on_click(cx.listener(move |this, _, _, cx| {
                if !this.expanded_groups.remove(&group_id) {
                    this.expanded_groups.insert(group_id.clone());
                }
                cx.notify();
            }));
        let mut column = v_flex().gap(px(10.)).child(header);
        if expanded {
            for item in &group.items {
                column = column.child(self.render_tool(item, cx));
            }
        }
        ui::grouped_surface(cx)
            .w_full()
            .py(px(8.))
            .px(px(10.))
            .child(column)
    }

    fn render_tool(&mut self, item: &TranscriptItem, cx: &mut Context<Self>) -> AnyElement {
        let TranscriptItem::Tool {
            id,
            name,
            args_json,
            output,
            status,
        } = item
        else {
            return div().into_any_element();
        };
        let lb = cx.lb().clone();
        let details_open = self.expanded_details.contains(id);
        let detail_id = id.clone();
        let preview = ResultPreview::tool(item);
        let icon: AnyElement = match status {
            ToolStatus::Running => Spinner::new()
                .xsmall()
                .color(lb.text_secondary)
                .into_any_element(),
            ToolStatus::Succeeded => {
                ui::icon(Ico::CircleCheck, px(13.), lb.text_secondary).into_any_element()
            }
            ToolStatus::Failed => {
                ui::icon(Ico::CircleAlert, px(13.), lb.attention_text).into_any_element()
            }
        };
        let body = if output.is_empty() {
            args_json.clone()
        } else {
            format!("{args_json}\n\n{output}")
        };
        h_flex()
            .w_full()
            .gap(px(8.))
            .items_start()
            .child(div().pt(px(2.)).child(icon))
            .child(
                v_flex()
                    .flex_1()
                    .min_w_0()
                    .gap(px(5.))
                    .child(
                        div()
                            .text_size(ty::SECONDARY)
                            .text_color(lb.text)
                            .child(activity_summary(name, args_json)),
                    )
                    .child(
                        h_flex()
                            .id(SharedString::from(format!("agent-tool-details-{id}")))
                            .gap(px(4.))
                            .items_center()
                            .cursor_pointer()
                            .text_size(ty::CAPTION)
                            .text_color(lb.text_secondary)
                            .child(ui::icon(
                                if details_open {
                                    Ico::ChevronDown
                                } else {
                                    Ico::ChevronRight
                                },
                                px(10.),
                                lb.text_secondary,
                            ))
                            .child(crate::ui::text::paragraph(lokalbot_i18n::tr("Details")))
                            .on_click(cx.listener(move |this, _, _, cx| {
                                if !this.expanded_details.remove(&detail_id) {
                                    this.expanded_details.insert(detail_id.clone());
                                }
                                cx.notify();
                            })),
                    )
                    .when(details_open, |this| {
                        this.child(
                            div()
                                .id(SharedString::from(format!("agent-tool-body-{id}")))
                                .max_h(px(180.))
                                .overflow_y_scroll()
                                .p(px(8.))
                                .rounded(px(6.))
                                .bg(lb.chip_fill)
                                .font_family(mono_font(cx))
                                .text_size(ty::CAPTION)
                                .text_color(lb.text)
                                .child(body),
                        )
                    }),
            )
            .when_some(preview, |this, preview| {
                this.child(
                    Button::new(SharedString::from(format!("agent-tool-open-{id}")))
                        .ghost()
                        .xsmall()
                        .label(lokalbot_i18n::tr("Open"))
                        .tooltip(lokalbot_i18n::format(
                            "Open {name} result",
                            &[("name", name.to_string())],
                        ))
                        .on_click(cx.listener(move |this, _, _, cx| {
                            this.show_preview(preview.clone(), cx)
                        })),
                )
            })
            .into_any_element()
    }

    /// Task errors (`sessions.error`, an alert on macOS) appear as a toast once.
    pub(super) fn show_task_error(&mut self, cx: &mut Context<Self>) {
        let Some(error) = self
            .model(cx)
            .and_then(|m| m.tasks.as_ref())
            .and_then(|t| t.error.clone())
        else {
            return;
        };
        if let Some(model) = &self.model {
            model.update(cx, |model, _| {
                if let Some(tasks) = model.tasks.as_mut() {
                    tasks.error = None;
                }
            });
        }
        self.data.update(cx, |data, cx| data.show_error(error, cx));
    }
}

/// Centers a row at the reading width.
fn centered(element: AnyElement) -> AnyElement {
    h_flex()
        .w_full()
        .justify_center()
        .child(
            div()
                .w_full()
                .max_w(metric::READING_MAX_WIDTH)
                .child(element),
        )
        .into_any_element()
}

pub(super) fn mono_font(cx: &App) -> SharedString {
    use gpui_kit::component::ActiveTheme as _;
    cx.theme().mono_font_family.clone()
}

/// Agent answers cite attached sources by their identifiers, often as
/// Markdown links such as `[meeting:<id>](meeting:<id>)` or
/// `[Title](moment:<n>)`. The shared answer renderer shows `[meeting:<id>]`
/// and `[screen:<n>]` markers as numbered references, so links to a source
/// and bare moment ids become those markers.
fn cite_sources(text: &str) -> Cow<'_, str> {
    if !text.contains("meeting:") && !text.contains("moment:") && !text.contains("screen:") {
        return Cow::Borrowed(text);
    }
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(open) = rest.find('[') {
        out.push_str(&rest[..open]);
        let tail = &rest[open..];
        match source_reference(tail) {
            Some((consumed, replacement)) => {
                out.push_str(&replacement);
                rest = &tail[consumed..];
            }
            None => {
                out.push('[');
                rest = &tail[1..];
            }
        }
    }
    out.push_str(rest);
    Cow::Owned(out)
}

/// At a `[`: a `[label](source)` link or a bare `[moment:<n>]`, as the
/// length to replace and its replacement.
fn source_reference(tail: &str) -> Option<(usize, String)> {
    let close = tail.find(']')?;
    let label = &tail[1..close];
    if label.contains(['[', '\n']) {
        return None;
    }
    if let Some(link) = tail[close + 1..].strip_prefix('(') {
        let end = link.find(')')?;
        let target = link[..end].trim();
        let marker = source_marker(target)?;
        let label = label.trim();
        let replacement = if label.is_empty() || source_marker(label).is_some() {
            marker
        } else {
            lokalbot_i18n::format(
                "{label} {marker}",
                &[("label", label.to_string()), ("marker", marker.to_string())],
            )
        };
        return Some((close + 2 + end + 1, replacement));
    }
    let marker = label
        .strip_prefix("moment:")
        .and_then(|_| source_marker(label))?;
    Some((close + 1, marker))
}

/// `meeting:<id>[@m:ss]` → `[meeting:<id>[@m:ss]]`; `moment:<n>` or
/// `screen:<n>` → `[screen:<n>]`.
fn source_marker(target: &str) -> Option<String> {
    if let Some(id) = target.strip_prefix("meeting:") {
        let valid = id.len() >= 3
            && id
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '@' | ':'));
        return valid.then(|| format!("[meeting:{id}]"));
    }
    let id = target
        .strip_prefix("moment:")
        .or_else(|| target.strip_prefix("screen:"))?;
    let valid = !id.is_empty() && id.chars().all(|c| c.is_ascii_digit());
    valid.then(|| format!("[screen:{id}]"))
}

#[cfg(test)]
mod tests {
    use super::cite_sources;

    #[test]
    fn source_links_become_reference_markers() {
        let id = "55555555-5555-4555-8555-555555555555";
        assert_eq!(
            cite_sources(&format!(
                "The meeting ([meeting:{id}](meeting:{id})) was short."
            )),
            format!("The meeting ([meeting:{id}]) was short.")
        );
        assert_eq!(
            cite_sources(&format!("See [Holiday shoot](meeting:{id}@1:05).")),
            format!("See Holiday shoot [meeting:{id}@1:05].")
        );
        assert_eq!(
            cite_sources("Saved in [moment:42] and [the window](moment:43)."),
            "Saved in [screen:42] and the window [screen:43]."
        );
    }

    #[test]
    fn other_links_and_brackets_stay() {
        for text in [
            "Plain [link](https://example.com) and [x] and [moment:abc].",
            "No sources here.",
            "Unclosed [meeting:12345678",
            "[label](meeting:has space)",
        ] {
            assert_eq!(cite_sources(text), text);
        }
    }
}
